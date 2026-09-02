import Foundation

/// A counting semaphore you can `await` instead of block on, with two priority lanes.
///
/// `DispatchSemaphore.wait()` would work here too — and it is what most people reach
/// for — but it parks an entire cooperative-pool thread. With a small pool that is how
/// you deadlock a Swift concurrency app. This one suspends the *task* and leaves the
/// thread free.
///
/// The two lanes exist because a plain FIFO gate has a nasty failure mode in a photo
/// grid: prefetch requests queue up ahead of the tile the user is actually looking at,
/// so lookahead makes the visible content *slower*. `.interactive` waiters are always
/// admitted before `.background` ones.
///
/// Cancellation is the part that's easy to get wrong: a task cancelled while parked
/// must be removed from the waiter list and must not consume a permit, or the pipeline
/// leaks capacity and eventually stalls with nothing running.
actor AsyncSemaphore {
    enum Lane { case interactive, background }

    private var permits: Int
    private var interactive: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    private var background: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    /// Waiters that exist but may not have suspended yet.
    private var active: Set<UUID> = []
    /// Cancelled after `onCancel` fired but before the continuation was stored.
    private var cancelledBeforeSuspend: Set<UUID> = []

    init(permits: Int) {
        self.permits = max(1, permits)
    }

    func setPermits(_ new: Int) {
        let delta = max(1, new) - permits
        permits = max(1, new)
        if delta > 0 { for _ in 0..<delta { resumeOneIfPossible() } }
    }

    func wait(lane: Lane = .interactive) async throws {
        if permits > 0 {
            permits -= 1
            return
        }

        let id = UUID()
        active.insert(id)
        // Both of these run on the actor with no suspension between them and the
        // return, so `cancelWaiter` cannot interleave and strand an entry. Without
        // this, `cancelledBeforeSuspend` grows for the lifetime of the process.
        defer {
            active.remove(id)
            cancelledBeforeSuspend.remove(id)
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // The cancellation handler can fire before we ever get here.
                if cancelledBeforeSuspend.contains(id) {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                switch lane {
                case .interactive: interactive.append((id, continuation))
                case .background: background.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func signal() {
        permits += 1
        resumeOneIfPossible()
    }

    private func resumeOneIfPossible() {
        guard permits > 0 else { return }
        let next: (id: UUID, continuation: CheckedContinuation<Void, any Error>)?
        if !interactive.isEmpty {
            next = interactive.removeFirst()
        } else if !background.isEmpty {
            next = background.removeFirst()
        } else {
            next = nil
        }
        guard let next else { return }
        permits -= 1
        next.continuation.resume()
    }

    private func cancelWaiter(_ id: UUID) {
        guard active.contains(id) else { return }   // already returned; nothing to do

        if let index = interactive.firstIndex(where: { $0.id == id }) {
            let waiter = interactive.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        } else if let index = background.firstIndex(where: { $0.id == id }) {
            let waiter = background.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            cancelledBeforeSuspend.insert(id)
        }
    }
}
