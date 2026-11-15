import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-262: which control verbs a selected row may use.
struct LeoAgentControlAvailabilityTests {
    private static let control = LeoDaemonFeatures(["agent_control"])

    private static func row(_ status: LeoAgentStatus, host: LeoHostID = .local, wake: Bool? = nil, movedTo: String? = nil, activity: LeoActivity = .working) -> LeoAgentRow {
        LeoAgentRow(host: host, name: "alpha", template: nil, status: status, activity: activity, actionDetail: nil, wakeOnMessage: wake, movedTo: movedTo)
    }

    private static func all(_ a: LeoAgentControlAvailability) -> [Bool] { [a.canInterrupt, a.canCompact, a.canClear] }

    @Test func requiresAgentControlFeature() {
        let availability = LeoAgentControlAvailability(row: Self.row(.running), features: LeoDaemonFeatures(["bridge_turns"]), deniedHosts: [], inFlight: nil)
        #expect(Self.all(availability) == [false, false, false])
    }

    @Test func noRowOffersNothing() {
        let availability = LeoAgentControlAvailability(row: nil, features: Self.control, deniedHosts: [], inFlight: nil)
        #expect(Self.all(availability) == [false, false, false])
    }

    @Test func runningEnablesAllThree() {
        let availability = LeoAgentControlAvailability(row: Self.row(.running), features: Self.control, deniedHosts: [], inFlight: nil)
        #expect(Self.all(availability) == [true, true, true])
    }

    @Test(arguments: [LeoAgentStatus.stopped, .starting, .unknown("weird")])
    func notRunningDisablesAll(status: LeoAgentStatus) {
        let availability = LeoAgentControlAvailability(row: Self.row(status), features: Self.control, deniedHosts: [], inFlight: nil)
        #expect(Self.all(availability) == [false, false, false])
    }

    @Test func aMovedAgentAllowsNothing() {
        let moved = Self.row(.stopped, wake: true, movedTo: "nas")
        let availability = LeoAgentControlAvailability(row: moved, features: Self.control, deniedHosts: [], inFlight: nil)
        #expect(Self.all(availability) == [false, false, false])
    }

    @Test func restoringDisablesAll() {
        let availability = LeoAgentControlAvailability(row: Self.row(.restoring), features: Self.control, deniedHosts: [], inFlight: nil)
        #expect(Self.all(availability) == [false, false, false])
    }

    @Test func stoppedWithoutWakeOnMessageAllowsNothing() {
        for wake in [false, nil] as [Bool?] {
            let availability = LeoAgentControlAvailability(row: Self.row(.stopped, wake: wake), features: Self.control, deniedHosts: [], inFlight: nil)
            #expect(Self.all(availability) == [false, false, false])
        }
    }

    @Test func deniedHostDisablesAllOthersUnaffected() {
        let denied: Set<LeoHostID> = [.remote("work")]
        let onWork = LeoAgentControlAvailability(row: Self.row(.running, host: .remote("work")), features: Self.control, deniedHosts: denied, inFlight: nil)
        #expect(Self.all(onWork) == [false, false, false])
        let onLocal = LeoAgentControlAvailability(row: Self.row(.running), features: Self.control, deniedHosts: denied, inFlight: nil)
        #expect(Self.all(onLocal) == [true, true, true])
    }

    @Test func idleAgentCannotBeInterruptedButStillCompactsAndClears() {
        let availability = LeoAgentControlAvailability(row: Self.row(.running, activity: .idle), features: Self.control, deniedHosts: [], inFlight: nil)
        #expect(!availability.canInterrupt)
        #expect([availability.canCompact, availability.canClear] == [true, true])
    }

    @Test(arguments: [LeoActivity.working, .unknown])
    func workingOrUnknownActivityAllowsInterrupt(activity: LeoActivity) {
        let availability = LeoAgentControlAvailability(row: Self.row(.running, activity: activity), features: Self.control, deniedHosts: [], inFlight: nil)
        #expect(availability.canInterrupt)
    }

    @Test func inFlightActionDisablesTheRest() {
        let availability = LeoAgentControlAvailability(row: Self.row(.running), features: Self.control, deniedHosts: [], inFlight: .compact)
        #expect(Self.all(availability) == [false, false, false])
    }
}
