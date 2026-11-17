import Foundation
import Testing

@testable import LeoKit

/// B-410: a tab's camera, microphone and location answers. Only the user
/// answers, only while the tab is on screen, and an answer lasts for the
/// tab's life, per site and kind.
struct LeoBrowserPermissionLedgerTests {
    private static let meet = LeoBrowserPermissionSite(scheme: "https", host: "meet.example.com", port: 8443)

    private func request(_ kind: LeoBrowserPermissionKind, _ site: LeoBrowserPermissionSite = meet) -> LeoBrowserPermissionRequest {
        LeoBrowserPermissionRequest(kind: kind, site: site)
    }

    @Test func hiddenDeniesWithoutAskingOrRemembering() {
        let ledger = LeoBrowserPermissionLedger()
        #expect(ledger.decision(for: request(.camera), isShown: false) == .deny)
        // Even an earlier allow: a hidden pane never grants.
        let allowed = ledger.remembering(request(.camera), allowed: true)
        #expect(allowed.decision(for: request(.camera), isShown: false) == .deny)
        // The auto-deny left nothing behind: shown, it asks.
        #expect(ledger.decision(for: request(.camera), isShown: true) == .ask)
    }

    @Test func shownUnknownAsks() {
        let ledger = LeoBrowserPermissionLedger()
        for kind in LeoBrowserPermissionKind.allCases {
            #expect(ledger.decision(for: request(kind), isShown: true) == .ask)
        }
    }

    @Test func answersAreRememberedPerSiteAndKind() {
        let ledger = LeoBrowserPermissionLedger()
            .remembering(request(.camera), allowed: true)
            .remembering(request(.location), allowed: false)
        #expect(ledger.decision(for: request(.camera), isShown: true) == .allow)
        #expect(ledger.decision(for: request(.location), isShown: true) == .deny)
        #expect(ledger.decision(for: request(.microphone), isShown: true) == .ask)

        let otherHost = LeoBrowserPermissionSite(scheme: "https", host: "evil.example.com", port: 8443)
        let otherPort = LeoBrowserPermissionSite(scheme: "https", host: "meet.example.com", port: 9443)
        let otherScheme = LeoBrowserPermissionSite(scheme: "http", host: "meet.example.com", port: 8443)
        for site in [otherHost, otherPort, otherScheme] {
            #expect(ledger.decision(for: request(.camera, site), isShown: true) == .ask)
            #expect(ledger.decision(for: request(.location, site), isShown: true) == .ask)
        }
    }

    @Test func cameraAndMicrophoneNeedsBoth() {
        let none = LeoBrowserPermissionLedger()
        let cameraOnly = none.remembering(request(.camera), allowed: true)
        let both = cameraOnly.remembering(request(.microphone), allowed: true)
        let micDenied = cameraOnly.remembering(request(.microphone), allowed: false)

        #expect(none.decision(for: request(.cameraAndMicrophone), isShown: true) == .ask)
        #expect(cameraOnly.decision(for: request(.cameraAndMicrophone), isShown: true) == .ask)
        #expect(both.decision(for: request(.cameraAndMicrophone), isShown: true) == .allow)
        #expect(micDenied.decision(for: request(.cameraAndMicrophone), isShown: true) == .deny)

        // Answering the pair answers each part.
        let pair = none.remembering(request(.cameraAndMicrophone), allowed: true)
        #expect(pair.decision(for: request(.camera), isShown: true) == .allow)
        #expect(pair.decision(for: request(.microphone), isShown: true) == .allow)
    }

    @Test func aDefaultPortIsTheSameSiteAsNoPort() {
        let bare = LeoBrowserPermissionSite(scheme: "HTTPS", host: "Meet.Example.com", port: nil)
        let explicit = LeoBrowserPermissionSite(scheme: "https", host: "meet.example.com", port: 443)
        #expect(bare == explicit)
        #expect(bare.label == "meet.example.com")
        #expect(Self.meet.label == "meet.example.com:8443")
        #expect(Self.meet.origin == "https://meet.example.com:8443")
        #expect(LeoBrowserPermissionSite(scheme: "about", host: "", port: nil).label == "this page")
    }

    @Test func aSiteRoundTripsThroughAURL() throws {
        let url = try #require(Self.meet.url)
        #expect(url.absoluteString == "https://meet.example.com:8443")
        #expect(LeoBrowserPermissionSite(url: url) == Self.meet)
        let loopback = LeoBrowserPermissionSite(scheme: "http", host: "::1", port: 5173)
        #expect(loopback.url?.absoluteString == "http://[::1]:5173")
        #expect(loopback.url.flatMap(LeoBrowserPermissionSite.init(url:)) == loopback)
    }
}
