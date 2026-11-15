import Testing

@testable import LeoFeatures

struct ConfigClientsTests {
    @Test func aDaemonKeepsTheSameRevisionTrackerBetweenLookups() {
        let revisions = ConfigClients.trackers()

        revisions("daemon-a").recordWrite(from: "sha256:1", to: "sha256:2")

        #expect(revisions("daemon-a") === revisions("daemon-a"))
        #expect(revisions("daemon-a").resolve("sha256:1") == "sha256:2")
    }

    @Test func eachDaemonHasItsOwnRevisionTracker() {
        let revisions = ConfigClients.trackers()

        revisions("daemon-a").recordWrite(from: "sha256:1", to: "sha256:2")

        #expect(revisions("daemon-a") !== revisions("daemon-b"))
        #expect(revisions("daemon-b").resolve("sha256:1") == "sha256:1")
    }
}
