import Foundation
import Testing

@testable import Ghostty

struct LeoSidebarFeedFetchRaceTests {
    /// `cancel()` landing before `install(_:)` (e.g. the surrounding Task
    /// was already cancelled when `withCheckedContinuation`'s body runs)
    /// must not leak the continuation -- it has to resume immediately with
    /// cancellation, or the caller hangs forever.
    @Test func installAfterCancelResumesImmediatelyWithCancellation() async {
        let race = LeoListFetchRace()
        race.cancel()

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<[LeoAgent], Error>, Never>) in
            race.install(continuation)
        }

        switch result {
        case .failure(is CancellationError): break
        default: Issue.record("expected .failure(CancellationError), got \(result)")
        }
    }
}
