import Foundation
import Testing
@testable import Filtr

/// The behaviours the architecture claims. Each of these fails loudly if the
/// corresponding technique in `PipelineConfig` regresses.
@Suite("Render coordinator")
struct RenderCoordinatorTests {

    // MARK: Coalescing

    @Test("Identical concurrent requests share one render")
    func identicalRequestsCoalesce() async throws {
        let renderer = FakeRenderer(heldOpen: true)
        let coordinator = RenderCoordinator(renderer: renderer, config: .testing())
        let key = RenderCoordinator.Key.stub()

        let tasks = (0..<8).map { _ in
            Task { try await coordinator.image(for: key, priority: .userInitiated) }
        }

        try await renderer.waitForInvocations(1)
        try await Task.sleep(for: .milliseconds(60))   // let the other seven subscribe
        await renderer.release()

        for task in tasks {
            #expect(try await task.value.cgImage.width == 4)
        }
        #expect(await renderer.invocations == 1, "eight callers should produce one render")
    }

    @Test("With coalescing off, identical requests duplicate the work")
    func withoutCoalescingWorkIsDuplicated() async throws {
        var config = PipelineConfig.testing()
        config.coalesceRequests = false
        let renderer = FakeRenderer()
        let coordinator = RenderCoordinator(renderer: renderer, config: config)
        let key = RenderCoordinator.Key.stub()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try? await coordinator.image(for: key, priority: .userInitiated) }
            }
        }

        #expect(await renderer.invocations == 8)
    }

    // MARK: Reference-counted cancellation

    @Test("One subscriber leaving does not cancel work the others still need")
    func cancellingOneSubscriberKeepsSharedWorkAlive() async throws {
        let renderer = FakeRenderer(heldOpen: true)
        let coordinator = RenderCoordinator(renderer: renderer, config: .testing())
        let key = RenderCoordinator.Key.stub()

        let leaving = Task { try await coordinator.image(for: key, priority: .userInitiated) }
        let staying = (0..<2).map { _ in
            Task { try await coordinator.image(for: key, priority: .userInitiated) }
        }

        try await renderer.waitForInvocations(1)
        try await Task.sleep(for: .milliseconds(60))

        leaving.cancel()
        try await Task.sleep(for: .milliseconds(60))
        await renderer.release()

        for task in staying {
            let image = try await task.value
            #expect(image.cgImage.width == 4, "a remaining subscriber must still get its image")
        }
        #expect(await renderer.cancelledRuns == 0, "the shared render must not have been cancelled")
        #expect(await renderer.completedRuns == 1)
    }

    @Test("When the last subscriber leaves, the work is cancelled")
    func lastSubscriberLeavingCancelsTheWork() async throws {
        let renderer = FakeRenderer(heldOpen: true)
        let coordinator = RenderCoordinator(renderer: renderer, config: .testing())
        let key = RenderCoordinator.Key.stub()

        let tasks = (0..<3).map { _ in
            Task { try await coordinator.image(for: key, priority: .userInitiated) }
        }

        try await renderer.waitForInvocations(1)
        try await Task.sleep(for: .milliseconds(60))
        for task in tasks { task.cancel() }

        try await withTimeout(.seconds(3)) {
            while await renderer.cancelledRuns == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(await renderer.cancelledRuns == 1)
        #expect(await renderer.completedRuns == 0)
    }

    @Test("Cancellation can be disabled")
    func cancellationCanBeDisabled() async throws {
        var config = PipelineConfig.testing()
        config.honorCancellation = false
        let renderer = FakeRenderer(heldOpen: true)
        let coordinator = RenderCoordinator(renderer: renderer, config: config)
        let key = RenderCoordinator.Key.stub()

        let task = Task { try await coordinator.image(for: key, priority: .userInitiated) }
        try await renderer.waitForInvocations(1)
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()
        try await Task.sleep(for: .milliseconds(100))

        #expect(await renderer.cancelledRuns == 0, "work should keep running when cancellation is off")
        await renderer.release()
    }

    // MARK: Admission control

    @Test("Concurrent renders never exceed the permit budget")
    func concurrencyStaysWithinBudget() async throws {
        let permits = 3
        let renderer = FakeRenderer(heldOpen: true)
        let coordinator = RenderCoordinator(renderer: renderer, config: .testing(permits: permits))

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = try? await coordinator.image(
                        for: .stub(photo: .stub(id: index)), priority: .userInitiated
                    )
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
            await renderer.release()
        }

        #expect(await renderer.peakConcurrent <= permits)
        #expect(await renderer.invocations == 20, "every distinct key must still be rendered")
    }

    @Test("With the gate off, fan-out is unbounded")
    func withoutBoundingFanOutIsUnbounded() async throws {
        var config = PipelineConfig.testing(permits: 3)
        config.boundConcurrency = false
        let renderer = FakeRenderer(heldOpen: true)
        let coordinator = RenderCoordinator(renderer: renderer, config: config)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = try? await coordinator.image(
                        for: .stub(photo: .stub(id: index)), priority: .userInitiated
                    )
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
            await renderer.release()
        }

        // The failure mode the semaphore exists to prevent.
        #expect(await renderer.peakConcurrent > 3)
    }

    // MARK: Caching

    @Test("A finished render is served from cache")
    func finishedRendersAreCached() async throws {
        let renderer = FakeRenderer()
        let coordinator = RenderCoordinator(renderer: renderer, config: .testing())
        let key = RenderCoordinator.Key.stub()

        for _ in 0..<3 {
            _ = try await coordinator.image(for: key, priority: .userInitiated)
        }
        #expect(await renderer.invocations == 1)
    }

    @Test("With the cache off, every request re-renders")
    func withoutCacheEveryRequestRenders() async throws {
        var config = PipelineConfig.testing()
        config.useCache = false
        let renderer = FakeRenderer()
        let coordinator = RenderCoordinator(renderer: renderer, config: config)
        let key = RenderCoordinator.Key.stub()

        for _ in 0..<3 {
            _ = try await coordinator.image(for: key, priority: .userInitiated)
        }
        #expect(await renderer.invocations == 3)
    }

    @Test("Different edits are different renders")
    func differentEditsDoNotShareResults() async throws {
        let renderer = FakeRenderer()
        let coordinator = RenderCoordinator(renderer: renderer, config: .testing())
        let photo = Photo.stub()

        _ = try await coordinator.image(for: .stub(photo: photo, recipe: .original), priority: .userInitiated)
        _ = try await coordinator.image(for: .stub(photo: photo, recipe: FilterRecipe.recipe(id: "A6")), priority: .userInitiated)
        _ = try await coordinator.image(
            for: .stub(photo: photo, adjustments: Adjustments(exposure: 0.5)), priority: .userInitiated
        )

        #expect(await renderer.invocations == 3)
    }
}
