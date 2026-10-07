import Foundation
import Testing

@testable import Ghostty

/// B-262: which control verbs a selected row may use.
struct LeoAgentControlAvailabilityTests {
    private static let control = LeoDaemonFeatures(["agent_control"])

    private static func row(_ status: LeoAgentStatus, host: LeoHostID = .local, wake: Bool? = nil) -> LeoAgentRow {
        LeoAgentRow(host: host, name: "alpha", template: nil, status: status, activity: .idle, actionDetail: nil, wakeOnMessage: wake)
    }

    private static func all(_ a: LeoAgentControlAvailability) -> [Bool] { [a.canSend, a.canInterrupt, a.canCompact, a.canClear] }

    @Test func requiresAgentControlFeature() {
        let availability = LeoAgentControlAvailability(row: Self.row(.running), features: LeoDaemonFeatures(["bridge_turns"]), deniedHosts: [], inFlight: nil)
        #expect(!availability.isOffered)
        #expect(Self.all(availability) == [false, false, false, false])
    }

    @Test func noRowOffersNothing() {
        let availability = LeoAgentControlAvailability(row: nil, features: Self.control, deniedHosts: [], inFlight: nil)
        #expect(!availability.isOffered)
        #expect(Self.all(availability) == [false, false, false, false])
    }

    @Test func runningEnablesAllFour() {
        let availability = LeoAgentControlAvailability(row: Self.row(.running), features: Self.control, deniedHosts: [], inFlight: nil)
        #expect(availability.isOffered)
        #expect(Self.all(availability) == [true, true, true, true])
        #expect(availability.reason == nil)
    }

    @Test(arguments: [LeoAgentStatus.stopped, .starting, .unknown("weird")])
    func notRunningDisablesAllWithAReason(status: LeoAgentStatus) {
        let availability = LeoAgentControlAvailability(row: Self.row(status), features: Self.control, deniedHosts: [], inFlight: nil)
        #expect(availability.isOffered)
        #expect(Self.all(availability) == [false, false, false, false])
        #expect(availability.reason != nil)
    }

    @Test func stoppedWithWakeOnMessageAllowsOnlySend() {
        let availability = LeoAgentControlAvailability(row: Self.row(.stopped, wake: true), features: Self.control, deniedHosts: [], inFlight: nil)
        #expect(Self.all(availability) == [true, false, false, false])
        #expect(availability.canCompose)
    }

    @Test func stoppedWithoutWakeOnMessageAllowsNothing() {
        for wake in [false, nil] as [Bool?] {
            let availability = LeoAgentControlAvailability(row: Self.row(.stopped, wake: wake), features: Self.control, deniedHosts: [], inFlight: nil)
            #expect(Self.all(availability) == [false, false, false, false])
            #expect(!availability.canCompose)
        }
    }

    @Test func fieldStaysComposableWhileAnActionIsInFlight() {
        let availability = LeoAgentControlAvailability(row: Self.row(.running), features: Self.control, deniedHosts: [], inFlight: .message)
        #expect(!availability.canSend)
        #expect(availability.canCompose)
    }

    @Test func deniedHostDisablesAllOthersUnaffected() {
        let denied: Set<LeoHostID> = [.remote("work")]
        let onWork = LeoAgentControlAvailability(row: Self.row(.running, host: .remote("work")), features: Self.control, deniedHosts: denied, inFlight: nil)
        #expect(Self.all(onWork) == [false, false, false, false])
        #expect(!onWork.canCompose)
        #expect(onWork.reason == LeoAgentControlAvailability.deniedReason)
        let onLocal = LeoAgentControlAvailability(row: Self.row(.running), features: Self.control, deniedHosts: denied, inFlight: nil)
        #expect(Self.all(onLocal) == [true, true, true, true])
    }

    @Test func inFlightActionDisablesTheRest() {
        let availability = LeoAgentControlAvailability(row: Self.row(.running), features: Self.control, deniedHosts: [], inFlight: .compact)
        #expect(Self.all(availability) == [false, false, false, false])
        #expect(availability.isOffered)
    }
}
