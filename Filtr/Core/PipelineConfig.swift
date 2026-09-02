import Foundation

/// Every guarantee the render pipeline makes, expressed as a switch you can turn off.
///
/// The point of the Lab screen is that each of these is a real technique with a real
/// failure mode. Flip one off, hit "Restyle All", and the HUD shows you the damage.
struct PipelineConfig: Sendable, Equatable {

    /// Share one in-flight `Task` between every caller asking for the same render key.
    /// OFF: N visible tiles asking for the same image do N identical renders.
    var coalesceRequests = true

    /// Gate renders behind an async semaphore sized to the machine.
    /// OFF: unbounded fan-out — every request starts immediately, thermals and
    /// peak memory go with it.
    var boundConcurrency = true

    /// Check `Task.isCancelled` at each pipeline stage and drop work for tiles that
    /// have scrolled away. OFF: you finish rendering images nobody is looking at,
    /// while the tiles on screen wait behind them.
    var honorCancellation = true

    /// Keep finished renders in an NSCache. OFF: scrolling back up re-renders.
    var useCache = true

    /// Decode source JPEGs straight to the size we need via ImageIO.
    /// OFF: full-resolution decode of a 3000px source for a 120pt tile —
    /// roughly 20 MB of bitmap per photo instead of 0.2 MB.
    var downsampleSources = true

    /// Run the Core Image render on the main thread. The cardinal sin, included
    /// so you can watch the hitch counter climb while you scroll.
    var renderOnMainThread = false

    /// Give visible work `.userInitiated` and prefetch `.utility`.
    /// OFF: everything is `.medium` and the OS can't tell what you're waiting on.
    var usePriorityHints = true

    /// Ceiling for simultaneous renders when `boundConcurrency` is on.
    var maxConcurrentRenders = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount))

    /// Extra passes per render, to simulate a heavier filter chain on fast hardware.
    var workMultiplier = 1

    static let strict = PipelineConfig()

    /// Every technique disabled — what a first-draft implementation usually does.
    static let naive = PipelineConfig(
        coalesceRequests: false,
        boundConcurrency: false,
        honorCancellation: false,
        useCache: false,
        downsampleSources: false,
        renderOnMainThread: false,
        usePriorityHints: false
    )
}
