import Foundation

/// A counting semaphore you can `await` instead of block on.
///
/// `DispatchSemaphore.wait()` would work here too — and it is what most people reach
/// for — but it parks an entire cooperative-pool thread. With a small pool that is how
/// you deadlock a Swift concurrency app. This one suspends the *task* and leaves the
/// thread free.
///
/// Cancellation is the part that's easy to get wrong: a task cancelled while parked
/// must be removed from the waiter list and must not consume a permit, or the pipeline
/// leaks capacity and eventually stalls with nothing running.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var cancelledBeforeSuspend: Set<UUID> = []

    init(permits: Int) {
        self.permits = max(1, permits)
    }

    func setPermits(_ new: Int) {
        let delta = max(1, new) - permits
        permits = max(1, new)
        if delta > 0 { for _ in 0..<delta { resumeOneIfPossible() } }
    }

    func wait() async throws {
        if permits > 0 {
            permits -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // The handler can fire before we ever get here; honour it.
                if cancelledBeforeSuspend.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = continuation
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
        guard permits > 0, let (id, continuation) = waiters.first else { return }
        waiters.removeValue(forKey: id)
        permits -= 1
        continuation.resume()
    }

    private func cancelWaiter(_ id: UUID) {
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledBeforeSuspend.insert(id)
        }
    }
}
