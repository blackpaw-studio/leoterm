import Foundation
import LeoKit
import Testing

@testable import Ghostty

/// The agent title menu's entries: order, separators, and what is enabled
/// for the shown agent.
struct LeoAgentTitleMenuItemsTests {
    typealias Items = LeoAgentTitleMenuItems

    private func context(
        status: LeoAgentStatus = .running, host: LeoHostID = .local, workspace: String? = "/work/agent",
        hasAgent: Bool = true, movesSupported: Bool = true, appearanceSupported: Bool = true
    ) -> Items.Context {
        Items.Context(
            agent: hasAgent
                ? Items.Context.Agent(
                    availability: LeoRowActionAvailability(status: status, isPending: false), host: host, workspace: workspace)
                : nil,
            movesSupported: movesSupported, appearanceSupported: appearanceSupported)
    }

    private func entries(_ context: Items.Context, exists: Bool = true) -> [Items.Entry] {
        Items.entries(for: context, fileExists: { _ in exists })
    }

    private func enabled(_ command: Items.Command, in entries: [Items.Entry]) -> Bool? {
        for case .command(let entry) in entries where entry.command == command { return entry.isEnabled }
        return nil
    }

    @Test func theOrderAndSeparatorsFollowTheSpec() {
        let layout = entries(context()).map { entry -> String in
            switch entry {
            case .separator: "-"
            case .command(let item): "\(item.command)"
            }
        }
        #expect(
            layout == [
                "start", "stop", "restart", "-", "revealWorkspace", "copyWorkspacePath", "-", "viewLogs", "moveTo", "rename",
                "appearance", "openInNewWindow",
            ])
    }

    @Test func deleteIsNotInTheMenu() {
        let titles = entries(context()).compactMap { entry -> String? in
            if case .command(let item) = entry { item.title } else { nil }
        }
        #expect(!titles.contains { $0.hasPrefix("Delete") })
    }

    @Test func titlesMatchTheSidebarMenu() {
        let titles = entries(context()).compactMap { entry -> String? in
            if case .command(let item) = entry { item.title } else { nil }
        }
        #expect(
            titles == [
                "Start", "Stop", "Restart", "Reveal Workspace in Finder", "Copy Workspace Path", "View Logs", "Move To", "Rename…",
                "Appearance…", "Open in New Window",
            ])
    }

    @Test func onlyTheValidLifecycleItemsAreEnabled() {
        let running = entries(context(status: .running))
        #expect(enabled(.start, in: running) == false)
        #expect(enabled(.stop, in: running) == true)
        #expect(enabled(.restart, in: running) == true)
        let stopped = entries(context(status: .stopped))
        #expect(enabled(.start, in: stopped) == true)
        #expect(enabled(.stop, in: stopped) == false)
        #expect(enabled(.restart, in: stopped) == false)
    }

    @Test func revealIsEnabledForALocalAgentWhoseWorkspaceExists() {
        #expect(enabled(.revealWorkspace, in: entries(context(), exists: true)) == true)
    }

    @Test func revealIsDisabledForARemoteAgent() {
        #expect(enabled(.revealWorkspace, in: entries(context(host: .remote("mac-mini")))) == false)
    }

    @Test func revealIsDisabledWhenTheWorkspaceIsGoneOrUnknown() {
        #expect(enabled(.revealWorkspace, in: entries(context(), exists: false)) == false)
        #expect(enabled(.revealWorkspace, in: entries(context(workspace: nil))) == false)
    }

    @Test func copyWorksForARemoteAgentAndNeedsAPath() {
        #expect(enabled(.copyWorkspacePath, in: entries(context(host: .remote("mac-mini")), exists: false)) == true)
        #expect(enabled(.copyWorkspacePath, in: entries(context(workspace: nil))) == false)
    }

    @Test func unsupportedItemsAreLeftOut() {
        let bare = entries(context(movesSupported: false, appearanceSupported: false))
        #expect(enabled(.moveTo, in: bare) == nil)
        #expect(enabled(.appearance, in: bare) == nil)
    }

    @Test func withNoAgentEverythingIsDisabled() {
        for case .command(let item) in entries(context(hasAgent: false)) { #expect(!item.isEnabled, "\(item.command)") }
    }
}
