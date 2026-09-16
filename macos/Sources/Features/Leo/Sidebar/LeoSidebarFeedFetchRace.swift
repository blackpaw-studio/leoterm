import Foundation

final class LeoListFetchRace: @unchecked Sendable {
    enum Winner { case list, deadline }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<[LeoAgent], Error>, Never>?
    private var listTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var finished = false

    /// If `cancel()`/`finish()` already ran (e.g. the surrounding Task was
    /// cancelled before `withCheckedContinuation`'s body even got to install
    /// its continuation), `finished` is already `true` and nothing else will
    /// ever resume this continuation -- resume it immediately with
    /// cancellation instead of leaking it (and hanging the caller) forever.
    func install(_ continuation: CheckedContinuation<Result<[LeoAgent], Error>, Never>) {
        let alreadyFinished = lock.withLock { () -> Bool in
            guard !finished else { return true }
            self.continuation = continuation
            return false
        }
        if alreadyFinished {
            continuation.resume(returning: .failure(CancellationError()))
        }
    }

    func install(listTask: Task<Void, Never>, deadlineTask: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            self.listTask = listTask
            self.deadlineTask = deadlineTask
            return finished
        }
        if shouldCancel {
            listTask.cancel()
            deadlineTask.cancel()
        }
    }

    func finish(_ result: Result<[LeoAgent], Error>, winner: Winner) {
        let resolution = lock.withLock { () -> (CheckedContinuation<Result<[LeoAgent], Error>, Never>, Task<Void, Never>?)? in
            guard !finished, let continuation else { return nil }
            finished = true
            self.continuation = nil
            let loser = switch winner {
            case .list: deadlineTask
            case .deadline: listTask
            }
            return (continuation, loser)
        }
        resolution?.0.resume(returning: result)
        resolution?.1?.cancel()
    }

    func cancel() {
        let resolution = lock.withLock { () -> (CheckedContinuation<Result<[LeoAgent], Error>, Never>?, Task<Void, Never>?, Task<Void, Never>?) in
            guard !finished else { return (nil, nil, nil) }
            finished = true
            let continuation = continuation
            self.continuation = nil
            return (continuation, listTask, deadlineTask)
        }
        resolution.0?.resume(returning: .failure(CancellationError()))
        resolution.1?.cancel()
        resolution.2?.cancel()
    }
}

enum LeoSidebarFeedError: Error, LocalizedError {
    case activityStateTimedOut
    case listTimedOut

    var errorDescription: String? {
        switch self {
        case .activityStateTimedOut, .listTimedOut: "timed out"
        }
    }
}
