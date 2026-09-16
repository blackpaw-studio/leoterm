import Foundation

final class LeoListFetchRace: @unchecked Sendable {
    enum Winner { case list, deadline }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<[LeoAgent], Error>, Never>?
    private var listTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Result<[LeoAgent], Error>, Never>) {
        lock.withLock { self.continuation = continuation }
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
