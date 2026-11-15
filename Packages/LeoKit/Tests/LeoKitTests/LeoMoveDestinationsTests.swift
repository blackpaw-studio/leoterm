import Testing

@testable import LeoKit

struct LeoMoveDestinationsTests {
    @Test func listsHostsSortedWithoutLocalhost() {
        #expect(LeoMoveDestinations.entries(hosts: ["nas", "localhost", "Work", "laptop"]) == .hosts(["laptop", "nas", "Work"]))
    }

    @Test func noOtherHostsIsAnEmptyList() {
        #expect(LeoMoveDestinations.entries(hosts: ["localhost"]) == .hosts([]))
    }

    @Test func aFailedLoadIsUnavailable() {
        #expect(LeoMoveDestinations.entries(hosts: nil) == .unavailable)
    }

    @Test func loadReadsTheHostNamesAndSwallowsFailure() async {
        #expect(await LeoMoveDestinations.load { ["b", "a"] } == .hosts(["a", "b"]))
        #expect(await LeoMoveDestinations.load { throw LeoDaemonError.timeout } == .unavailable)
    }
}
