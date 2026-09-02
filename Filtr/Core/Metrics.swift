import Foundation
import os
import QuartzCore

/// A point-in-time read of the pipeline. Cheap to copy, safe to hand to SwiftUI.
struct MetricsSnapshot: Sendable, Equatable {
    var inFlight = 0            // renders actually executing
    var waiting = 0             // admitted, parked on the concurrency gate
    var peakInFlight = 0
    var completed = 0
    var cancelled = 0
    var cacheHits = 0
    var cacheMisses = 0
    var coalesced = 0           // callers that joined an existing in-flight task
    var renderCount = 0
    var totalRenderMillis: Double = 0
    var lastRenderMillis: Double = 0
    var bytesDecoded: Int = 0
    var hitches = 0             // main-thread frames longer than 2x the target
    var worstFrameMillis: Double = 0
    var recent: [Double] = []   // ring buffer of render durations, for the sparkline

    var averageRenderMillis: Double { renderCount == 0 ? 0 : totalRenderMillis / Double(renderCount) }
    var cacheHitRate: Double {
        let total = cacheHits + cacheMisses
        return total == 0 ? 0 : Double(cacheHits) / Double(total)
    }
    /// Work that was started and then thrown away.
    var wasteRate: Double {
        let total = completed + cancelled
        return total == 0 ? 0 : Double(cancelled) / Double(total)
    }
}

/// Write side of the metrics. Hot paths call into this from arbitrary threads and
/// arbitrary isolation domains, so it is a lock over a plain struct rather than an
/// actor — an `await` on every counter bump would distort the thing we're measuring.
final class MetricsRecorder: Sendable {
    static let shared = MetricsRecorder()

    private let state = OSAllocatedUnfairLock(initialState: MetricsSnapshot())
    private static let ringCapacity = 120

    func snapshot() -> MetricsSnapshot { state.withLock { $0 } }

    func reset() {
        state.withLock { $0 = MetricsSnapshot() }
    }

    func cacheHit() { state.withLock { $0.cacheHits += 1 } }
    func cacheMiss() { state.withLock { $0.cacheMisses += 1 } }
    func coalescedRequest() { state.withLock { $0.coalesced += 1 } }

    func enteredQueue() { state.withLock { $0.waiting += 1 } }
    func leftQueue() { state.withLock { $0.waiting = max(0, $0.waiting - 1) } }

    func renderBegan() {
        state.withLock {
            $0.inFlight += 1
            $0.peakInFlight = max($0.peakInFlight, $0.inFlight)
        }
    }

    func renderEnded(millis: Double) {
        state.withLock {
            $0.inFlight = max(0, $0.inFlight - 1)
            $0.completed += 1
            $0.renderCount += 1
            $0.totalRenderMillis += millis
            $0.lastRenderMillis = millis
            $0.recent.append(millis)
            if $0.recent.count > Self.ringCapacity { $0.recent.removeFirst($0.recent.count - Self.ringCapacity) }
        }
    }

    func renderCancelled(wasRunning: Bool) {
        state.withLock {
            if wasRunning { $0.inFlight = max(0, $0.inFlight - 1) }
            $0.cancelled += 1
        }
    }

    func decoded(bytes: Int) { state.withLock { $0.bytesDecoded += bytes } }

    func frame(millis: Double, target: Double) {
        state.withLock {
            $0.worstFrameMillis = max($0.worstFrameMillis, millis)
            if millis > target * 2 { $0.hitches += 1 }
        }
    }
}

/// Read side. Polls the recorder on a display-linked cadence and republishes to SwiftUI.
///
/// The display link does double duty: it is also the stall detector. If a render is
/// hogging the main thread, this callback is exactly what stops arriving on time.
@MainActor
@Observable
final class MetricsStore {
    private(set) var snapshot = MetricsSnapshot()

    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var lastPublish: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        let proxy = DisplayLinkProxy { [weak self] link in self?.tick(link) }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.fire(_:)))
        link.add(to: .main, forMode: .common)
        self.proxy = proxy
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        proxy = nil
    }

    func reset() {
        MetricsRecorder.shared.reset()
        snapshot = MetricsSnapshot()
    }

    private var proxy: DisplayLinkProxy?

    private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastFrame > 0 {
            let target = (link.targetTimestamp - link.timestamp) * 1000
            MetricsRecorder.shared.frame(millis: (now - lastFrame) * 1000,
                                         target: target > 0 ? target : 16.67)
        }
        lastFrame = now

        // Republish at ~12 Hz. Driving @Observable at 120 Hz would itself become
        // the main-thread load we're trying to measure.
        if now - lastPublish > 0.08 {
            lastPublish = now
            snapshot = MetricsRecorder.shared.snapshot()
        }
    }
}

/// `CADisplayLink` needs an Objective-C target, and we added it to the main run loop,
/// so the callback is main-actor by construction — declaring it that way is both true
/// and enough for the compiler.
@MainActor
private final class DisplayLinkProxy: NSObject {
    private let handler: (CADisplayLink) -> Void
    init(handler: @escaping (CADisplayLink) -> Void) { self.handler = handler }
    @objc func fire(_ link: CADisplayLink) { handler(link) }
}
