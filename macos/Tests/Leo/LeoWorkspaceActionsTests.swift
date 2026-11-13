import Foundation
import LeoKit
import Testing

@testable import Ghostty

/// Reveal Workspace in Finder and Copy Workspace Path, with Finder and the
/// pasteboard faked.
struct LeoWorkspaceActionsTests {
    private final class Recorder {
        var revealed: [URL] = []
        var copied: [String] = []
    }

    private func actions(_ recorder: Recorder, exists: Bool = true) -> LeoWorkspaceActions {
        LeoWorkspaceActions(
            reveal: { recorder.revealed.append($0) }, copy: { recorder.copied.append($0) }, fileExists: { _ in exists })
    }

    @Test func revealGivesFinderTheWorkspaceFileURL() {
        let recorder = Recorder()
        let didReveal = actions(recorder).reveal(host: .local, workspace: "/work/agent")
        #expect(didReveal)
        #expect(recorder.revealed == [URL(fileURLWithPath: "/work/agent")])
    }

    @Test func revealForARemoteAgentDoesNothing() {
        let recorder = Recorder()
        #expect(!actions(recorder).reveal(host: .remote("mac-mini"), workspace: "/work/agent"))
        #expect(recorder.revealed.isEmpty)
    }

    @Test func revealForAMissingWorkspaceDoesNothing() {
        let recorder = Recorder()
        #expect(!actions(recorder, exists: false).reveal(host: .local, workspace: "/gone"))
        #expect(!actions(recorder).reveal(host: .local, workspace: nil))
        #expect(recorder.revealed.isEmpty)
    }

    @Test func copyPutsTheRemotePathOnTheClipboardVerbatim() {
        let recorder = Recorder()
        #expect(actions(recorder, exists: false).copyPath(workspace: "/srv/agents/leo"))
        #expect(recorder.copied == ["/srv/agents/leo"])
    }

    @Test func copyWithNoWorkspaceDoesNothing() {
        let recorder = Recorder()
        #expect(!actions(recorder).copyPath(workspace: nil))
        #expect(!actions(recorder).copyPath(workspace: ""))
        #expect(recorder.copied.isEmpty)
    }
}
