import Foundation
import Testing

@testable import Ghostty

/// A13: finding `claude`, the one install command, and offering setup once.
struct LeoClaudeOnboardingTests {
    private static let home = "/Users/evan"

    private static func locate(
        executables: Set<String>, loginPath: String? = nil
    ) -> (found: String?, probed: [String]) {
        var probed: [String] = []
        let locator = LeoClaudeLocator(
            home: home,
            isExecutable: { path in probed.append(path); return executables.contains(path) },
            loginPath: { loginPath }
        )
        return (locator.locate(), probed)
    }

    @Test func candidatesAreCheckedInTheDocumentedOrderThenTheLoginPath() {
        let result = Self.locate(executables: [], loginPath: "/a/bin:/b/bin")

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

    @Test func theFirstExecutableWinsAndStopsTheSearch() {
        let result = Self.locate(
            executables: ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"], loginPath: "/a/bin"
        )

        #expect(result.found == "/opt/homebrew/bin/claude")
        #expect(result.probed.last == "/opt/homebrew/bin/claude")
    }

    @Test func aLoginPathHitIsFoundWhenNothingFixedExists() {
        #expect(Self.locate(executables: ["/a/bin/claude"], loginPath: "/a/bin").found == "/a/bin/claude")
    }

    @Test func relativeAndEmptyLoginPathEntriesAreNeverProbed() {
        let result = Self.locate(executables: [], loginPath: "bin::./x:/ok")

        #expect(result.probed.suffix(1) == ["/ok/claude"])
        #expect(result.probed.count == 5)
    }

    @Test func theInstallCommandIsTheOfficialOneThenLogin() {
        #expect(LeoClaudeOnboarding.installCommand == #"curl -fsSL https://claude.ai/install.sh | bash && "$HOME/.local/bin/claude""#)
    }

    @Test(arguments: [
        (nil as String?, false, true, true),
        ("/usr/local/bin/claude", false, true, false),
        (nil, true, true, false),
        (nil, false, false, false),
    ])
    func theOfferNeedsMissingClaudeFirstRunAndALiveLocalDaemon(
        claude: String?, alreadyShown: Bool, live: Bool, expected: Bool
    ) {
        #expect(LeoClaudeOnboarding.shouldOffer(claudePath: claude, alreadyShown: alreadyShown, hasLiveLocalDaemon: live) == expected)
    }

    @Test func theOfferIsRememberedAcrossStores() {
        let defaults = LeoInMemoryDefaults()
        #expect(!LeoClaudeOnboardingStore(defaults: defaults).wasOffered)

        LeoClaudeOnboardingStore(defaults: defaults).markOffered()

        #expect(LeoClaudeOnboardingStore(defaults: defaults).wasOffered)
        #expect(defaults.bool(forKey: "leo.claudeOnboardingOffered"))
    }
}
