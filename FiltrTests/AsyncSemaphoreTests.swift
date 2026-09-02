import Foundation
import Testing
@testable import Filtr

@Suite("Async semaphore")
struct AsyncSemaphoreTests {

    @Test("Permits limit how many callers run at once")
    func permitsAreRespected() async throws {
        let semaphore = AsyncSemaphore(permits: 2)
        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try? await semaphore.wait()
                    await tracker.enter()
                    try? await Task.sleep(for: .milliseconds(20))
                    await tracker.leave()
                    await semaphore.signal()
                }
            }
        }

        #expect(await tracker.peak <= 2)
    }

    /// The bug this guards: a task cancelled while parked must not consume a permit.
    /// If it does, the pipeline slowly loses capacity and eventually stalls with
    /// nothing running — a hang that only reproduces under fast scrolling.
    @Test("Cancelling a parked waiter does not leak its permit")
    func cancelledWaiterDoesNotLeakAPermit() async throws {
        let semaphore = AsyncSemaphore(permits: 1)
        try await semaphore.wait()                       // hold the only permit

        let parked = Task { try await semaphore.wait() }
        try await Task.sleep(for: .milliseconds(50))
        parked.cancel()
        _ = try? await parked.value

        await semaphore.signal()                         // give the original permit back

        // If the cancelled waiter had swallowed a permit, this would hang forever.
        try await withTimeout(.seconds(2)) {
            try await semaphore.wait()
        }
    }

    @Test("Interactive waiters are admitted ahead of background ones")
    func interactiveLaneWinsRegardlessOfArrivalOrder() async throws {
        let semaphore = AsyncSemaphore(permits: 1)
        try await semaphore.wait()                       // hold it so both park
        let order = OrderRecorder()

        let background = Task {
            try await semaphore.wait(lane: .background)
            await order.record("background")
        }
        try await Task.sleep(for: .milliseconds(60))     // background parks first

        let interactive = Task {
            try await semaphore.wait(lane: .interactive)
            await order.record("interactive")
        }
        try await Task.sleep(for: .milliseconds(60))

        await semaphore.signal()                          // one permit for two waiters
        try await Task.sleep(for: .milliseconds(60))
        await semaphore.signal()

        _ = try? await interactive.value
        _ = try? await background.value

        #expect(await order.entries == ["interactive", "background"],
                "prefetch must never overtake the tile the user is looking at")
    }

    @Test("Raising the permit count releases parked waiters")
    func raisingPermitsReleasesWaiters() async throws {
        let semaphore = AsyncSemaphore(permits: 1)
        try await semaphore.wait()

        let parked = Task { try await semaphore.wait() }
        try await Task.sleep(for: .milliseconds(50))

        await semaphore.setPermits(3)
        try await withTimeout(.seconds(2)) { _ = try await parked.value }
    }
}

private actor ConcurrencyTracker {
    private(set) var peak = 0
    private var current = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}
