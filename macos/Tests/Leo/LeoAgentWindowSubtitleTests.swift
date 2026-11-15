import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The agent window's subtitle: `<cwd, ~-abbreviated> · <harness>`.
struct LeoAgentWindowSubtitleTests {
    private let home = "/Users/evan"

    private func text(_ workspace: String?, _ harness: String?, host: LeoHostID = .local, remoteUser: String? = nil) -> String {
        LeoAgentWindowSubtitle.text(workspace: workspace, harness: harness, host: host, localHome: home, remoteUser: remoteUser)
    }

    @Test func abbreviatesLocalHomeAndAppendsHarness() {
        #expect(text("/Users/evan/code/leo", "claude") == "~/code/leo · claude")
        #expect(text("/Users/evan", "codex") == "~ · codex")
    }

    @Test func doesNotAbbreviateALookalikePrefix() {
        #expect(text("/Users/evangeline/code", "claude") == "/Users/evangeline/code · claude")
    }

    @Test func missingHarnessLeavesTheCwdAlone() {
        #expect(text("/Users/evan/code", nil) == "~/code")
        #expect(text("/Users/evan/code", "") == "~/code")
    }

    @Test func missingWorkspaceShowsHarnessOnly() {
        #expect(text(nil, "claude") == "claude")
        #expect(text("", "claude") == "claude")
    }

    @Test func nothingKnownIsEmpty() {
        #expect(text(nil, nil).isEmpty)
    }

    @Test func remoteCollapsesOnlyForTheHostsOwnLogin() {
        let remote = LeoHostID.remote("mars")
        #expect(text("/home/deploy/app", "claude", host: remote, remoteUser: "deploy") == "~/app · claude")
        #expect(text("/Users/deploy/app", "claude", host: remote, remoteUser: "deploy") == "~/app · claude")
        #expect(text("/home/other/app", "claude", host: remote, remoteUser: "deploy") == "/home/other/app · claude")
    }

    @Test func remoteWithUnknownUserShowsTheFullPath() {
        #expect(text("/home/deploy/app", "claude", host: .remote("mars")) == "/home/deploy/app · claude")
        // The laptop's own home must not collapse a remote path.
        #expect(text("/Users/evan/app", "claude", host: .remote("mars")) == "/Users/evan/app · claude")
    }
}
