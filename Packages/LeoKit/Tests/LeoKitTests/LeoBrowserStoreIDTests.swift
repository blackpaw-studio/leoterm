import Foundation
import Testing

@testable import LeoKit

struct LeoBrowserStoreIDTests {
    @Test func uuidV5MatchesTheRFC4122Vector() {
        let dns = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        #expect(LeoBrowserStoreID.uuidV5(namespace: dns, name: "www.example.com").uuidString == "2ED6657D-E927-568B-95E1-2665A8AEA6A2")
    }

    @Test func theSameMachineAndAgentAlwaysGetTheSameID() {
        #expect(LeoBrowserStoreID.identifier(machineID: "dionysus", agent: "alfred") == LeoBrowserStoreID.identifier(machineID: "dionysus", agent: "alfred"))
    }

    @Test func differentAgentsAndMachinesGetDifferentIDs() {
        let base = LeoBrowserStoreID.identifier(machineID: "dionysus", agent: "alfred")
        #expect(base != LeoBrowserStoreID.identifier(machineID: "dionysus", agent: "rocket"))
        #expect(base != LeoBrowserStoreID.identifier(machineID: "hestia", agent: "alfred"))
    }

    @Test func theSeparatorKeepsAmbiguousNamesApart() {
        #expect(LeoBrowserStoreID.identifier(machineID: "ab", agent: "c") != LeoBrowserStoreID.identifier(machineID: "a", agent: "bc"))
    }

    @Test func aStableIDIsPinnedSoTheStoreSurvivesAppUpdates() {
        // A change here orphans every agent's cookies on disk; update only on purpose.
        #expect(LeoBrowserStoreID.identifier(machineID: "local", agent: "alfred").uuidString == LeoBrowserStoreIDTests.pinned)
    }

    static let pinned = "A859AC03-E303-5483-B11F-1C03F56D30A2"
}
