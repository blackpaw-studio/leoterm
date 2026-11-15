import Foundation
import Testing

@testable import Ghostty

/// A13: finding `claude`, the one install command, and remembering the offer.
struct LeoClaudeOnboardingTests {
    private static let home = "/Users/evan"

    private static func locate(
        executables: Set<String>, loginPath: String? = nil
    ) async -> (found: String?, probed: [String], loginPathQueries: Int) {
        var probed: [String] = []
        var loginPathQueries = 0
        let locator = LeoClaudeLocator(
            home: home,
            isExecutable: { path in probed.append(path); return executables.contains(path) },
            loginPath: { loginPathQueries += 1; return loginPath }
        )
        return (await locator.locate(), probed, loginPathQueries)
    }

    @Test func candidatesAreCheckedInTheDocumentedOrderThenTheLoginPath() async {
        let result = await Self.locate(executables: [], loginPath: "/a/bin:/b/bin")

        #expect(result.found == nil)
        #expect(result.probed == [
            "/Users/evan/.local/bin/claude",
            "/Users/evan/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/a/bin/claude",
            "/b/bin/claude",
        ])
    }

    @Test func theFirstExecutableWinsAndStopsTheSearch() async {
        let result = await Self.locate(
            executables: ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"], loginPath: "/a/bin"
        )

        #expect(result.found == "/opt/homebrew/bin/claude")
        #expect(result.probed.last == "/opt/homebrew/bin/claude")
    }

    @Test func theLoginShellIsNotSpawnedWhenAFixedLocationHasClaude() async {
        let result = await Self.locate(executables: ["/Users/evan/.local/bin/claude"], loginPath: "/a/bin")

        #expect(result.found == "/Users/evan/.local/bin/claude")
        #expect(result.loginPathQueries == 0)
    }

    @Test func aLoginPathHitIsFoundWhenNothingFixedExists() async {
        #expect(await Self.locate(executables: ["/a/bin/claude"], loginPath: "/a/bin").found == "/a/bin/claude")
    }

    @Test func relativeAndEmptyLoginPathEntriesAreNeverProbed() async {
        let result = await Self.locate(executables: [], loginPath: "bin::./x:/ok")

        #expect(result.probed.suffix(1) == ["/ok/claude"])
        #expect(result.probed.count == 5)
    }

    @Test func theInstallCommandIsTheOfficialOneThenLogin() {
        #expect(LeoClaudeOnboarding.installCommand == #"curl -fsSL https://claude.ai/install.sh | bash && "$HOME/.local/bin/claude""#)
    }

    @Test func theOfferIsRememberedAcrossStores() {
        let defaults = LeoInMemoryDefaults()
        #expect(!LeoClaudeOnboardingStore(defaults: defaults).wasOffered)

        LeoClaudeOnboardingStore(defaults: defaults).markOffered()

        #expect(LeoClaudeOnboardingStore(defaults: defaults).wasOffered)
        #expect(defaults.bool(forKey: "leo.claudeOnboardingOffered"))
    }
}
