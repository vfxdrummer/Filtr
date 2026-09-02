import CoreGraphics
import Foundation

/// The single front door for "give me this photo, with this filter, at this size".
///
/// Everything the interview question is really about lives here:
///
/// * **Cache** — finished renders, cost-limited, evicted under memory pressure.
/// * **Coalescing** — one in-flight `Task` per key, shared by every caller.
/// * **Reference-counted cancellation** — a caller going away cancels *its* interest,
///   not the shared work. Only the last one out turns off the lights.
/// * **Bounded concurrency** — an async gate, so a fling-scroll over 96 tiles doesn't
///   start 96 renders.
/// * **Priority** — visible work outranks prefetch, and Swift escalates a shared job
///   automatically when a higher-priority caller joins it.
actor RenderCoordinator {
    static let shared = RenderCoordinator()

    /// The step that actually produces pixels.
    ///
    /// The coordinator's job is *policy* — who gets admitted, what gets shared, what
    /// gets thrown away. Core Image is the *mechanism*. Splitting them means the policy
    /// can be tested deterministically (a fake renderer that blocks on command and
    /// counts its own invocations) instead of by rendering real photographs and hoping
    /// the timing works out.
    private let renderer: any PixelRenderer

    init(renderer: any PixelRenderer = CoreImageRenderer(), config: PipelineConfig = PipelineConfig()) {
        self.renderer = renderer
        self.config = config
        self.semaphore = AsyncSemaphore(permits: config.maxConcurrentRenders)
    }

    // MARK: - Key

    struct Key: Hashable, Sendable {
        let photoID: Int
        let sourceName: String
        let cropSeed: Int
        let recipeID: String
        let intensityBucket: Int
        let adjustments: Adjustments
        let maxPixel: Int
        let workMultiplier: Int

        init(
            photo: Photo,
            recipe: FilterRecipe,
            intensity: Double,
            adjustments: Adjustments = .neutral,
            maxPixel: CGFloat,
            workMultiplier: Int
        ) {
            self.photoID = photo.id
            self.sourceName = photo.sourceName
            self.cropSeed = photo.cropSeed
            self.recipeID = recipe.id
            // Bucket the slider. A continuous Double as a cache key means every
            // pixel of drag is a brand new render that can never be reused.
            self.intensityBucket = Int((intensity * 20).rounded())
            // Same reason as the intensity bucket: a raw Double from a slider drag
            // would make every key unique and the cache useless.
            self.adjustments = adjustments.quantized()
            self.maxPixel = Int((maxPixel / 32).rounded(.up)) * 32
            self.workMultiplier = workMultiplier
        }

        var intensity: Double { Double(intensityBucket) / 20 }
        var normalizedCrop: CGRect {
            Photo(id: photoID, sourceName: sourceName, cropSeed: cropSeed).normalizedCrop
        }
        /// Ask the decoder for more pixels than the tile needs, because we're about to
        /// throw most of them away in the crop.
        var sourceMaxPixel: CGFloat { CGFloat(maxPixel) * 1.8 }

        var cacheKey: NSString {
            "\(photoID)|\(recipeID)|\(intensityBucket)|\(adjustments.keyFragment)|\(maxPixel)|\(workMultiplier)" as NSString
        }
    }

    // MARK: - State

    private final class Job {
        let id = UUID()
        let task: Task<ImageBox, any Error>
        var subscribers = 0
        init(task: Task<ImageBox, any Error>) { self.task = task }
    }

    private final class CacheEntry {
        let box: ImageBox
        init(_ box: ImageBox) { self.box = box }
    }

    private let cache: NSCache<NSString, CacheEntry> = {
        let cache = NSCache<NSString, CacheEntry>()
        cache.totalCostLimit = 96 * 1024 * 1024   // NSCache evicts under memory pressure
        cache.countLimit = 600
        return cache
    }()

    private var inFlight: [Key: Job] = [:]
    private var config: PipelineConfig
    private var semaphore: AsyncSemaphore

    // MARK: - Configuration

    func update(config newValue: PipelineConfig) async {
        let boundChanged = newValue.maxConcurrentRenders != config.maxConcurrentRenders
        // Any switch that changes pixels invalidates what we've already cached.
        let outputChanged = newValue.downsampleSources != config.downsampleSources
            || newValue.workMultiplier != config.workMultiplier
        config = newValue
        if boundChanged { await semaphore.setPermits(newValue.maxConcurrentRenders) }
        if outputChanged {
            cache.removeAllObjects()
            await SourceImageLoader.shared.purge()
        }
    }

    func purge() async {
        cache.removeAllObjects()
        for (_, job) in inFlight { job.task.cancel() }
        inFlight.removeAll()
        await SourceImageLoader.shared.purge()
    }

    // MARK: - The request path

    func image(for key: Key, priority: TaskPriority) async throws -> ImageBox {
        if config.useCache, let hit = cache.object(forKey: key.cacheKey) {
            MetricsRecorder.shared.cacheHit()
            return hit.box
        }
        MetricsRecorder.shared.cacheMiss()

        let job = existingOrNewJob(for: key, priority: priority)
        job.subscribers += 1
        let jobID = job.id

        return try await withTaskCancellationHandler {
            do {
                let box = try await job.task.value
                finish(key: key, jobID: jobID, result: box)
                return box
            } catch {
                finish(key: key, jobID: jobID, result: nil)
                throw error
            }
        } onCancel: {
            // Non-isolated and synchronous, so hop back on to touch actor state.
            // Key and jobID are both Sendable value types; the Job itself never leaves.
            Task { await self.subscriberWentAway(key: key, jobID: jobID) }
        }
    }

    /// Fire-and-forget warmup for tiles about to scroll into view.
    func prefetch(_ keys: [Key]) {
        guard !keys.isEmpty else { return }
        for key in keys {
            if config.useCache, cache.object(forKey: key.cacheKey) != nil { continue }
            if inFlight[key] != nil { continue }
            let job = existingOrNewJob(for: key, priority: config.usePriorityHints ? .utility : .medium)
            job.subscribers += 1
            let jobID = job.id
            // Capture the `Task` (Sendable) rather than the `Job` box (a plain class
            // that never leaves the actor).
            let task = job.task
            Task { [weak self] in
                let box = try? await task.value
                await self?.finish(key: key, jobID: jobID, result: box)
            }
        }
    }

    // MARK: - Internals

    private func existingOrNewJob(for key: Key, priority: TaskPriority) -> Job {
        if config.coalesceRequests, let existing = inFlight[key], !existing.task.isCancelled {
            MetricsRecorder.shared.coalescedRequest()
            return existing
        }

        let effectivePriority = config.usePriorityHints ? priority : .medium
        let config = self.config
        let semaphore = self.semaphore
        let renderer = self.renderer

        // `Task.detached`, not `Task {}`. An unstructured `Task` created inside an actor
        // inherits that actor's isolation, which would run every render *on the
        // coordinator* and serialise the whole pipeline behind its single executor.
        let lane: AsyncSemaphore.Lane = priority <= .utility ? .background : .interactive
        let task = Task<ImageBox, any Error>.detached(priority: effectivePriority) {
            try await RenderCoordinator.execute(
                key: key, config: config, semaphore: semaphore, lane: lane, renderer: renderer
            )
        }

        let job = Job(task: task)
        if config.coalesceRequests { inFlight[key] = job }
        return job
    }

    private func finish(key: Key, jobID: UUID, result: ImageBox?) {
        if let result, config.useCache {
            cache.setObject(CacheEntry(result), forKey: key.cacheKey, cost: result.byteCount)
        }
        if let job = inFlight[key], job.id == jobID {
            job.subscribers = max(0, job.subscribers - 1)
            inFlight[key] = nil   // the task has finished; it can never be joined again
        }
    }

    private func subscriberWentAway(key: Key, jobID: UUID) {
        guard config.honorCancellation else { return }
        guard let job = inFlight[key], job.id == jobID else { return }
        job.subscribers -= 1
        // The whole point of the refcount: three tiles shared this render, one scrolled
        // off, the other two still need it. Cancelling here would be a bug that only
        // shows up as intermittently blank cells under fast scrolling.
        if job.subscribers <= 0 {
            job.task.cancel()
            inFlight[key] = nil
        }
    }

    // MARK: - The actual work (deliberately outside the actor)

    private nonisolated static func execute(
        key: Key,
        config: PipelineConfig,
        semaphore: AsyncSemaphore,
        lane: AsyncSemaphore.Lane,
        renderer: any PixelRenderer
    ) async throws -> ImageBox {

        func checkpoint() throws {
            if config.honorCancellation { try Task.checkCancellation() }
        }

        try checkpoint()

        var holdsPermit = false
        if config.boundConcurrency {
            MetricsRecorder.shared.enteredQueue()
            do {
                try await semaphore.wait(lane: lane)
            } catch {
                MetricsRecorder.shared.leftQueue()
                MetricsRecorder.shared.renderCancelled(wasRunning: false)
                throw error
            }
            MetricsRecorder.shared.leftQueue()
            holdsPermit = true
        }
        defer {
            if holdsPermit { Task { await semaphore.signal() } }
        }

        do {
            try checkpoint()
            return try await renderer.makeImage(for: key, config: config)
        } catch {
            throw error
        }
    }
}
