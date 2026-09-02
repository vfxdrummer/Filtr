import CoreGraphics
import Foundation

/// Produces the pixels for one render key.
///
/// The seam between the coordinator's *policy* (admission control, coalescing,
/// cancellation, caching) and the *mechanism* that actually burns GPU time. Tests
/// substitute a fake that blocks on command and counts its own invocations, which is
/// what makes claims like "identical requests run once" and "peak concurrency never
/// exceeds the limit" provable instead of merely plausible.
protocol PixelRenderer: Sendable {
    func makeImage(for key: RenderCoordinator.Key, config: PipelineConfig) async throws -> ImageBox
}

/// The production path: decode the source at the size we need, then run the filter
/// chain on a queue that's allowed to block.
struct CoreImageRenderer: PixelRenderer {

    func makeImage(for key: RenderCoordinator.Key, config: PipelineConfig) async throws -> ImageBox {
        func checkpoint() throws {
            if config.honorCancellation { try Task.checkCancellation() }
        }

        var didBeginRender = false
        do {
            let source = try await SourceImageLoader.shared.image(
                named: key.sourceName,
                maxPixel: key.sourceMaxPixel,
                downsample: config.downsampleSources,
                useCache: config.useCache
            )

            // Decoding a JPEG is slow enough that the tile which asked for it is often
            // gone by the time we get here.
            try checkpoint()

            let request = FilterEngine.Request(
                recipe: FilterRecipe.recipe(id: key.recipeID),
                intensity: key.intensity,
                adjustments: key.adjustments,
                normalizedCrop: key.normalizedCrop,
                targetMaxPixel: CGFloat(key.maxPixel),
                workMultiplier: config.workMultiplier
            )

            MetricsRecorder.shared.renderBegan()
            didBeginRender = true
            let started = CFAbsoluteTimeGetCurrent()

            let output: ImageBox
            if config.renderOnMainThread {
                output = try await MainActor.run {
                    try FilterEngine.shared.render(source, request: request)
                }
            } else {
                // Hand the synchronous Core Image work to a queue that is allowed to
                // block, so we never tie up a cooperative-pool thread with it.
                output = try await withTaskExecutorPreference(RenderTaskExecutor.shared) {
                    try checkpoint()
                    return try FilterEngine.shared.render(source, request: request)
                }
            }

            MetricsRecorder.shared.renderEnded(millis: (CFAbsoluteTimeGetCurrent() - started) * 1000)
            didBeginRender = false
            return output
        } catch {
            MetricsRecorder.shared.renderCancelled(wasRunning: didBeginRender)
            throw error
        }
    }
}
