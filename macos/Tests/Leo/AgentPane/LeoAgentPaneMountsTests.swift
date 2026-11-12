import Combine
import Testing

@testable import Ghostty
@testable import LeoKit

/// Which pane slots are mounted, and so on screen and reporting visibility
/// (the host view reports while it is in a window), for each pane state.
@MainActor
struct LeoAgentPaneMountsTests {
    private let ref = LeoPluginAgentRef(machine: "Local", name: "alfred")
    private let identity = LeoAgentIdentity(host: .local, name: "alfred", workspace: "/w/alfred")
    private var agent: LeoAgentPaneAgent { LeoAgentPaneAgent(ref: ref, identity: identity) }
    private let terminal = LeoAgentPaneTab.terminal
    private let status = LeoAgentPaneTab(id: "p.status", kind: .plugin(paneID: "status"), title: "Status", sfSymbol: nil, hasWarning: false)
    private let github = LeoAgentPaneTab(id: "p.github", kind: .plugin(paneID: "gh"), title: "GitHub", sfSymbol: nil, hasWarning: false)

    private func slot(_ tab: LeoAgentPaneTab, _ part: LeoPluginPanePart) -> LeoPluginSlotKey {
        LeoPluginSlotKey(pluginID: tab.id, slot: .pane(id: tab.paneID ?? "", part: part, agent: ref))
    }

    private func key(_ tab: LeoAgentPaneTab, _ part: LeoPluginPanePart) -> LeoAgentPaneMount {
        .plugin(slot(tab, part))
    }

    @Test
    func collapsedMountsEverySummaryAndNoBody() {
        let mounts = LeoAgentPaneMounts(tabs: [status, github], state: LeoAgentPaneState(), agent: agent)
        #expect(mounts.summaries == [key(status, .summary), key(github, .summary)])
        #expect(mounts.body == nil)
    }

    @Test
    func expandedMountsOnlyTheSelectedTabsBodyBesideAllSummaries() {
        let state = LeoAgentPaneState(isExpanded: true, selectedTabID: "p.github")
        let mounts = LeoAgentPaneMounts(tabs: [status, github], state: state, agent: agent)
        #expect(mounts.summaries.count == 2)
        #expect(mounts.body == key(github, .body))
    }

    @Test
    func anExpandedPaneWhoseRememberedTabIsGoneShowsTheFirstTabsBody() {
        let state = LeoAgentPaneState(isExpanded: true, selectedTabID: "removed")
        #expect(LeoAgentPaneMounts(tabs: [status, github], state: state, agent: agent).body == key(status, .body))
    }

    @Test
    func noAgentOrNoTabsMountsNothing() {
        let state = LeoAgentPaneState(isExpanded: true, selectedTabID: "p.status")
        #expect(LeoAgentPaneMounts(tabs: [status], state: state, agent: nil) == LeoAgentPaneMounts.none)
        #expect(LeoAgentPaneMounts(tabs: [], state: state, agent: agent) == LeoAgentPaneMounts.none)
    }

    @Test
    func theKeysFollowTheAgent() {
        let other = LeoAgentPaneAgent(
            ref: LeoPluginAgentRef(machine: "Local", name: "rocket"), identity: LeoAgentIdentity(host: .local, name: "rocket"))
        let a = LeoAgentPaneMounts(tabs: [status], state: LeoAgentPaneState(), agent: agent)
        let b = LeoAgentPaneMounts(tabs: [status], state: LeoAgentPaneState(), agent: other)
        #expect(a.summaries != b.summaries)
    }

    @Test
    func aMountedSummaryReportsThroughTheRefCountedReporterOnlyWhileActive() {
        let surface = FakePaneSurface()
        let reporter = LeoPluginVisibilityReporter(key: slot(status, .body), surface: surface, isActive: false)
        reporter.setAppeared(true)
        #expect(surface.visible.isEmpty)
        reporter.setActive(true)
        #expect(surface.visible == [slot(status, .body): 1])
        reporter.setActive(false)
        #expect(surface.visible.isEmpty)
    }

    @Test
    func thePaneIsShownOnlyForASelectedAgentWithATab() {
        #expect(LeoAgentPaneModel.isShown(agent: agent, tabs: [status]))
        #expect(!LeoAgentPaneModel.isShown(agent: nil, tabs: [status]), "no agent selected: no strip")
        #expect(!LeoAgentPaneModel.isShown(agent: agent, tabs: []))
    }

    // MARK: Built-in Terminal

    @Test
    func aTerminalOnlyPaneIsShownWithAnAgentAndHiddenWithout() {
        #expect(LeoAgentPaneModel.isShown(agent: agent, tabs: [terminal]))
        #expect(!LeoAgentPaneModel.isShown(agent: nil, tabs: [terminal]))
        #expect(LeoAgentPaneMounts(tabs: [terminal], state: LeoAgentPaneState(), agent: nil) == LeoAgentPaneMounts.none)
    }

    @Test
    func collapsedTerminalMountsItsSummaryByIdentityBesideThePlugins() {
        let mounts = LeoAgentPaneMounts(tabs: [terminal, status], state: LeoAgentPaneState(), agent: agent)
        #expect(mounts.summaries == [.terminal(identity), key(status, .summary)])
        #expect(mounts.body == nil)
    }

    @Test
    func expandedOnTheTerminalMountsItsBodyAndNoPluginBody() {
        let state = LeoAgentPaneState(isExpanded: true, selectedTabID: "leo.terminal")
        let mounts = LeoAgentPaneMounts(tabs: [terminal, status], state: state, agent: agent)
        #expect(mounts.body == .terminal(identity))
        #expect(mounts.pluginKeys == [slot(status, .summary)])
    }

    @Test
    func theTerminalHasNoPluginSlotsToOpenOrReport() {
        let state = LeoAgentPaneState(isExpanded: true, selectedTabID: "p.status")
        let mounts = LeoAgentPaneMounts(tabs: [terminal, status], state: state, agent: agent)
        #expect(mounts.pluginKeys == [slot(status, .summary), slot(status, .body)])
    }
}

@MainActor private final class FakePaneSurface: LeoPluginSlotSurface {
    var visible: [LeoPluginSlotKey: Int] = [:]
    var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    func content(for key: LeoPluginSlotKey) -> LeoPluginSlotContent { .loading }
    func retry(_ key: LeoPluginSlotKey) {}
    func perform(_ action: LeoPluginAction, gesture: LeoPluginGesture?, in key: LeoPluginSlotKey) {}
    func pop(_ key: LeoPluginSlotKey) {}
    func setVisible(_ key: LeoPluginSlotKey, _ visible: Bool) {
        let next = (self.visible[key] ?? 0) + (visible ? 1 : -1)
        self.visible[key] = next > 0 ? next : nil
    }
}
