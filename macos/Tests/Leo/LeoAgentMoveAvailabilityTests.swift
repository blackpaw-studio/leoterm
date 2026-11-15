import Testing

@testable import Ghostty
@testable import LeoKit

/// B-324: which row actions a moved or live agent allows.
struct LeoAgentMoveAvailabilityTests {
    @Test(arguments: [LeoAgentStatus.running, .stopped])
    func aLiveOrStoppedRowCanMoveCopyAndDuplicate(status: LeoAgentStatus) {
        let availability = LeoRowActionAvailability(status: status, isPending: false)
        #expect(availability.move)
        #expect(availability.copy)
        #expect(availability.duplicate)
    }

    @Test func aPendingOrRestoringRowCannotMove() {
        for availability in [LeoRowActionAvailability(status: .running, isPending: true), LeoRowActionAvailability(status: .restoring, isPending: false)] {
            #expect(!availability.move)
            #expect(!availability.copy)
            #expect(!availability.duplicate)
        }
    }

    @Test func aMovedRowCannotStartAttachOrMoveButCanStillBeDeleted() {
        let moved = LeoRowActionAvailability(status: .stopped, isPending: false, movedTo: "nas")
        #expect(moved.isMoved)
        #expect(!moved.start)
        #expect(!moved.attach)
        #expect(!moved.restart)
        #expect(!moved.rename)
        #expect(!moved.setTemplate)
        #expect(!moved.move)
        #expect(!moved.copy)
        #expect(!moved.duplicate)
        #expect(moved.delete)
        #expect(moved.logs)
    }
}
