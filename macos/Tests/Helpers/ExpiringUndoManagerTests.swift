import Foundation
import Testing

@testable import Ghostty

/// `ExpiringUndoManager.removeAllActions()` (B-083): each expiring
/// target's `deinit` re-enters `removeAllActions(withTarget:)`, so
/// clearing the set in place used to trip Swift's exclusivity check and
/// kill the process.
@MainActor
struct ExpiringUndoManagerTests {
    private final class Target {}

    private final class Calls {
        var count = 0
    }

    private func register(
        _ target: Target,
        in undoManager: ExpiringUndoManager,
        calls: Calls
    ) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: target, expiresAfter: .seconds(60)) { _ in calls.count += 1 }
        undoManager.endUndoGrouping()
    }

    private func makeUndoManager() -> ExpiringUndoManager {
        let undoManager = ExpiringUndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    @Test func removeAllActionsDropsExpiringUndosWithoutAnExclusivityViolation() throws {
        let undoManager = makeUndoManager()
        let targets = [Target(), Target()]
        let calls = Calls()
        targets.forEach { register($0, in: undoManager, calls: calls) }
        try #require(undoManager.canUndo)

        undoManager.removeAllActions()

        #expect(!undoManager.canUndo)
        undoManager.undo()
        #expect(calls.count == 0, "nothing cleared replays")
    }

    @Test func undoStillWorksAfterRemoveAllActions() throws {
        let undoManager = makeUndoManager()
        let target = Target()
        let calls = Calls()
        register(target, in: undoManager, calls: calls)
        undoManager.removeAllActions()

        register(target, in: undoManager, calls: calls)
        try #require(undoManager.canUndo)
        undoManager.undo()

        #expect(calls.count == 1)
    }
}
