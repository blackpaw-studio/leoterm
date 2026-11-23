import Foundation
import Testing

@testable import LeoKit

struct LeoPluginSourceTrustTests {
    private static let sha = String(repeating: "a", count: 40)

    private static func git(_ url: String) -> LeoPluginSource {
        .git(url: url, ref: "main", sha: sha)
    }

    @Test(arguments: [
        "https://github.com/blackpaw-studio/leo-plugin-usage",
        "https://GitHub.com/Blackpaw-Studio/x.git",
    ])
    func blackpawRepoIsVerified(url: String) {
        #expect(LeoPluginSourceTrust.classify(Self.git(url)) == .verified)
    }

    @Test(arguments: [
        "https://github.com.evil.com/blackpaw-studio/x",
        "https://github.com/blackpaw-studio-x/y",
        "https://evil.com/blackpaw-studio/x",
        "https://gitlab.com/blackpaw-studio/x",
        "https://www.github.com/blackpaw-studio/x",
        "https://github.com:443/blackpaw-studio/x",
        "https://github.com/someone/blackpaw-studio",
    ])
    func spoofsAreUnverified(url: String) {
        #expect(LeoPluginSourceTrust.classify(Self.git(url)) == .unverified)
    }

    /// Git (and the server) fold dot segments, so these name another owner's repo.
    @Test(arguments: [
        "https://github.com/blackpaw-studio/../attacker/plugin",
        "https://github.com/blackpaw-studio/./../attacker/plugin",
        "https://github.com/blackpaw-studio/%2e%2e/attacker/plugin",
        "https://github.com/blackpaw-studio/%2E%2E/attacker/plugin",
        "https://github.com/blackpaw-studio/.%2e/attacker/plugin",
        "https://github.com/blackpaw-studio/%2e./attacker/plugin",
        "https://github.com/blackpaw-studio/%252e%252e/attacker/plugin",
        "https://github.com/blackpaw-studio/./plugin",
        "https://github.com/blackpaw-studio/plugin/..",
        "https://github.com/%2e%2e/blackpaw-studio/plugin",
        "https://github.com/blackpaw%2Dstudio/plugin",
    ])
    func dotSegmentsAreUnverified(url: String) {
        #expect(LeoPluginSourceTrust.classify(Self.git(url)) == .unverified)
    }

    @Test func dotsInsideANameAreStillVerified() {
        #expect(LeoPluginSourceTrust.classify(Self.git("https://github.com/blackpaw-studio/leo.plugin..x")) == .verified)
    }

    @Test func nonHTTPSIsUnverified() {
        #expect(LeoPluginSourceTrust.classify(Self.git("file:///tmp/blackpaw-studio/x")) == .unverified)
        #expect(LeoPluginSourceTrust.classify(Self.git("http://github.com/blackpaw-studio/x")) == .unverified)
        #expect(LeoPluginSourceTrust.classify(Self.git("https://u:p@github.com/blackpaw-studio/x")) == .unverified)
    }

    @Test func localSourcesHaveNoLabel() {
        #expect(LeoPluginSourceTrust.classify(.bundled) == .notApplicable)
        #expect(LeoPluginSourceTrust.classify(.dev(path: "/tmp/plugin")) == .notApplicable)
    }
}
