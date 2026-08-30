import Testing
import Foundation
@testable import Ghostty

struct BoardPersistenceStateTests {
    @Test func idleControllerMayNotSave() {
        #expect(BoardPersistenceState.idle.canSave == false)
    }

    @Test func ownedControllerMayNotSaveBeforeRestoring() {
        var state = BoardPersistenceState.idle
        state.takeOwnership()
        #expect(state == .owned)
        #expect(state.canSave == false)
    }

    @Test func restoringControllerMayNotSave() {
        var state = BoardPersistenceState.owned
        state.beginRestore()
        #expect(state == .restoring)
        #expect(state.canSave == false)
    }

    @Test func successfulRestoreArmsSaving() {
        var state = BoardPersistenceState.owned
        state.beginRestore()
        state.finishRestore(succeeded: true)
        #expect(state == .armed)
        #expect(state.canSave)
    }

    @Test func failedRestoreLeavesSavingDisarmed() {
        var state = BoardPersistenceState.owned
        state.beginRestore()
        state.finishRestore(succeeded: false)
        #expect(state == .failed)
        #expect(state.canSave == false)
    }

    @Test func nonOwnersCannotBeArmedByAStrayCallback() {
        var state = BoardPersistenceState.idle
        state.finishRestore(succeeded: true)
        state.beginRestore()
        state.armForFreshBoard()
        #expect(state == .idle)
        #expect(state.canSave == false)
    }

    @Test func armingAfterAFreshBoardHasNothingToLose() {
        // No persisted board on disk: the owner arms immediately so the very
        // first cell the user adds is saved.
        var state = BoardPersistenceState.idle
        state.takeOwnership()
        state.armForFreshBoard()
        #expect(state.canSave)
    }

    @Test func armingAfterAFailedRestoreIsAllowedWhenNothingIsPersisted() {
        // The caller only arms when the board file is missing or empty, so
        // there is no saved board left for the failure to protect.
        var state = BoardPersistenceState.failed
        state.armForFreshBoard()
        #expect(state.canSave)
    }

    @Test func armingIsStillIgnoredForNonOwnersAndInFlightRestores() {
        var restoring = BoardPersistenceState.restoring
        restoring.armForFreshBoard()
        #expect(restoring == .restoring)
        var idle = BoardPersistenceState.idle
        idle.armForFreshBoard()
        #expect(idle == .idle)
    }

    @Test func failedRestoreAsksForARetry() {
        #expect(BoardPersistenceState.failed.needsRestoreRetry)
        #expect(BoardPersistenceState.armed.needsRestoreRetry == false)
    }

    @Test func retryingAFailedRestoreCanRearm() {
        var state = BoardPersistenceState.failed
        state.beginRestore()
        state.finishRestore(succeeded: true)
        #expect(state.canSave)
    }

    @Test func relinquishingTheLeaseStopsSaving() {
        // Window teardown empties the surface tree; an armed controller would
        // otherwise persist that emptiness as the user's board.
        var state = BoardPersistenceState.armed
        state.relinquish()
        #expect(state == .idle)
        #expect(state.canSave == false)
    }

    @Test func relinquishedControllerIgnoresLaterMembershipArming() {
        var state = BoardPersistenceState.armed
        state.relinquish()
        state.beginRestore()
        state.finishRestore(succeeded: true)
        #expect(state.canSave == false)
    }
}
