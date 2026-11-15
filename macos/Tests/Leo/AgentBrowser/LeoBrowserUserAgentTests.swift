import Foundation
import Testing

@testable import Ghostty

struct LeoBrowserUserAgentTests {
    @Test func usesTheInstalledSafariMajorAndMinor() {
        #expect(LeoBrowserUserAgent.applicationName(safariVersion: { "26.1.2" }) == "Version/26.1 Safari/605.1.15")
    }

    @Test func aBareMajorVersionGetsMinorZero() {
        #expect(LeoBrowserUserAgent.applicationName(safariVersion: { "27" }) == "Version/27.0 Safari/605.1.15")
    }

    @Test func fallsBackWhenSafariIsMissingOrUnreadable() {
        let fallback = "Version/\(LeoBrowserUserAgent.fallbackVersion) Safari/605.1.15"
        #expect(LeoBrowserUserAgent.applicationName(safariVersion: { nil }) == fallback)
        #expect(LeoBrowserUserAgent.applicationName(safariVersion: { "beta" }) == fallback)
    }
}
