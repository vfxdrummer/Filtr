import Foundation

/// A `TaskExecutor` backed by a private concurrent `DispatchQueue`.
///
/// Core Image's `render` is *synchronous* CPU/GPU work. Calling it from an ordinary
/// async function runs it on a cooperative-pool thread, and the cooperative pool has
/// roughly one thread per core with a hard rule against blocking them. A few
/// simultaneous renders and you have starved the pool that the rest of the app —
/// including anything the main actor is waiting on — needs to make progress.
///
/// `withTaskExecutorPreference` moves that blocking work onto a queue that is allowed
/// to block, while the surrounding code stays plain structured concurrency: still
/// cancellable, still awaitable, no continuation bridging by hand.
final class RenderTaskExecutor: TaskExecutor {
    static let shared = RenderTaskExecutor()

    private let queue = DispatchQueue(
        label: "com.timothybrandt.filtr.render",
        qos: .userInitiated,
        attributes: .concurrent
    )

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { [self] in
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}
