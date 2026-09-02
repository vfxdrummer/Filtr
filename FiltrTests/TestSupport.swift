import CoreGraphics
import Foundation
import Testing
@testable import Filtr

// MARK: - Fake renderer

/// A stand-in for Core Image that never touches a GPU.
///
/// It counts invocations, tracks how many calls are in flight simultaneously, and can
/// be held open until a test releases it. That's what turns the coordinator's
/// timing-dependent guarantees — "identical requests run once", "peak concurrency never
/// exceeds the budget" — into deterministic assertions instead of hopeful ones.
actor FakeRenderer: PixelRenderer {
    private(set) var invocations = 0
    private(set) var peakConcurrent = 0
    private(set) var cancelledRuns = 0
    private(set) var completedRuns = 0
    private(set) var seenKeys: [RenderCoordinator.Key] = []

    private var current = 0
    private var gateOpen: Bool
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var wokenBeforeParking: Set<UUID> = []

    /// `heldOpen: true` parks every call until `release()`.
    init(heldOpen: Bool = false) { gateOpen = !heldOpen }

    nonisolated func makeImage(for key: RenderCoordinator.Key, config: PipelineConfig) async throws -> ImageBox {
        await begin(key)
        do {
            try await waitForGate()
            try Task.checkCancellation()
            await finish(wasCancelled: false)
            return Self.stubImage()
        } catch {
            await finish(wasCancelled: true)
            throw error
        }
    }

    // MARK: Bookkeeping

    private func begin(_ key: RenderCoordinator.Key) {
        invocations += 1
        seenKeys.append(key)
        current += 1
        peakConcurrent = max(peakConcurrent, current)
    }

    private func finish(wasCancelled: Bool) {
        current -= 1
        if wasCancelled { cancelledRuns += 1 } else { completedRuns += 1 }
    }

    // MARK: The gate

    private func waitForGate() async throws {
        if gateOpen { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if gateOpen || wokenBeforeParking.remove(id) != nil {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            // Wake only *this* call, not every parked one — otherwise cancelling one
            // subscriber would silently let all the others through and the test would
            // be measuring the wrong thing.
            Task { await self.wake(id) }
        }
        try Task.checkCancellation()
    }

    private func wake(_ id: UUID) {
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume()
        } else {
            wokenBeforeParking.insert(id)
        }
    }

    func release() {
        gateOpen = true
        let parked = waiters
        waiters.removeAll()
        for (_, continuation) in parked { continuation.resume() }
    }

    /// Block until `count` calls have started, so assertions run against a known state.
    func waitForInvocations(_ count: Int, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while invocations < count {
            if ContinuousClock.now > deadline {
                throw TestFailure("only \(invocations) of \(count) invocations started")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    nonisolated static func stubImage() -> ImageBox {
        ImageBox(makeSolidImage(width: 4, height: 4, grey: 0.5))
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Async helpers

/// Fail fast instead of hanging the suite if a "this should not block" claim is wrong.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TestFailure("timed out after \(duration)")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

actor OrderRecorder {
    private(set) var entries: [String] = []
    func record(_ value: String) { entries.append(value) }
}

// MARK: - Image helpers

/// Everything in these tests is sRGB end to end — the source, the engine's working and
/// output spaces, and the readback.
///
/// Worth stating because getting it wrong is silent: a source tagged `DeviceRGB` picks
/// up a gamma conversion on its way through an sRGB `CIContext`, and flat 0.5 grey
/// comes back as 0.57. Every "did the filter change anything" assertion would then be
/// measuring a colour-space conversion instead of the filter.
let testColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func makeSolidImage(width: Int, height: Int, grey: Double) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: testColorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let color = CGColor(colorSpace: testColorSpace, components: [grey, grey, grey, 1])!
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

struct PixelStats {
    var mean: Double
    var min: Double
    var max: Double
    var standardDeviation: Double
    var meanChannelSpread: Double   // how far from grey, on average
}

/// Read a CGImage back into numbers so tests can assert on what the filter actually did.
func stats(of image: CGImage, region: CGRect? = nil) -> PixelStats {
    let width = image.width, height = image.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &buffer, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: testColorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let bounds = region.map {
        CGRect(x: $0.minX * CGFloat(width), y: $0.minY * CGFloat(height),
               width: $0.width * CGFloat(width), height: $0.height * CGFloat(height))
    } ?? CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))

    var luminance: [Double] = []
    var spreads: [Double] = []
    for y in Int(bounds.minY)..<Int(bounds.maxY) {
        for x in Int(bounds.minX)..<Int(bounds.maxX) {
            let i = (y * width + x) * 4
            let r = Double(buffer[i]) / 255, g = Double(buffer[i + 1]) / 255, b = Double(buffer[i + 2]) / 255
            luminance.append((r + g + b) / 3)
            spreads.append(Swift.max(r, g, b) - Swift.min(r, g, b))
        }
    }

    let mean = luminance.reduce(0, +) / Double(luminance.count)
    let variance = luminance.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(luminance.count)
    return PixelStats(
        mean: mean,
        min: luminance.min() ?? 0,
        max: luminance.max() ?? 0,
        standardDeviation: variance.squareRoot(),
        meanChannelSpread: spreads.reduce(0, +) / Double(spreads.count)
    )
}

// MARK: - Fixtures

extension Photo {
    static func stub(id: Int = 1, source: String = "src_00") -> Photo {
        Photo(id: id, sourceName: source, cropSeed: id &* 7919 &+ 13)
    }
}

extension RenderCoordinator.Key {
    static func stub(
        photo: Photo = .stub(),
        recipe: FilterRecipe = .original,
        intensity: Double = 1,
        adjustments: Adjustments = .neutral,
        maxPixel: CGFloat = 128
    ) -> RenderCoordinator.Key {
        .init(photo: photo, recipe: recipe, intensity: intensity,
              adjustments: adjustments, maxPixel: maxPixel, workMultiplier: 1)
    }
}

extension PipelineConfig {
    static func testing(permits: Int = 4) -> PipelineConfig {
        var config = PipelineConfig.strict
        config.maxConcurrentRenders = permits
        return config
    }
}

extension FilterEngine.Request {
    static func stub(
        recipe: FilterRecipe = .original,
        intensity: Double = 1,
        adjustments: Adjustments = .neutral,
        targetMaxPixel: CGFloat = 256
    ) -> FilterEngine.Request {
        .init(recipe: recipe, intensity: intensity, adjustments: adjustments,
              normalizedCrop: CGRect(x: 0, y: 0, width: 1, height: 1),
              targetMaxPixel: targetMaxPixel, workMultiplier: 1)
    }
}
