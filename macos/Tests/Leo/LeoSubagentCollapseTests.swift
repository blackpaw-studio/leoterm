import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-331: an agent row with dispatch children collapses just its own
/// dispatch rows; Hide Subagents collapses or expands every agent's at
/// once; the choice is remembered in the sidebar preferences.
@MainActor struct LeoSubagentCollapseTests {
    private func agent(_ name: String, status: LeoAgentStatus = .running) -> LeoAgentRow {
        LeoAgentRow(host: .local, name: name, template: nil, status: status, activity: .idle, actionDetail: nil)
    }

    private let alpha = LeoAgentRow(host: .local, name: "alpha", template: nil, status: .running, activity: .working, actionDetail: nil)
    private let beta = LeoAgentRow(host: .local, name: "beta", template: nil, status: .running, activity: .idle, actionDetail: nil)

    private func dispatch(_ id: String, status: String = "running", attachable: Bool = false) -> LeoDispatch {
        LeoDispatch(id: id, name: "n-\(id)", status: status, attachable: attachable)
    }

    private func snapshot(_ children: [String: [(LeoDispatch, Int)]]) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: [alpha, beta], connectivity: .connected, generation: 1,
            dispatchChildren: children.mapValues { $0.map { LeoDispatchNode(dispatch: $0.0, depth: $0.1) } },
            features: LeoDaemonFeatures(["dispatch_tree", "dispatch_attach"])
        )
    }

    private func model(
        store: any LeoSidebarPreferencesStore = LeoInMemorySidebarPreferencesStore()
    ) -> LeoSidebarModel {
        LeoSidebarModel(
            snapshot: snapshot([
                "alpha": [(dispatch("a1"), 0), (dispatch("a2", status: "queued"), 1), (dispatch("a3", status: "idle"), 0)],
                "beta": [(dispatch("b1", attachable: true), 0)],
            ]),
            preferencesStore: store
        )
    }

    private func shown(_ model: LeoSidebarModel, _ row: LeoAgentRow) -> [String] {
        model.visibleDispatchRows(for: row).map(\.id)
    }

    @Test func collapsingAnAgentHidesOnlyItsOwnDispatches() {
        let model = model()
        #expect(shown(model, alpha) == ["a1", "a2", "a3"])

        model.toggleSubagentsCollapsed(alpha)

        #expect(shown(model, alpha).isEmpty)
        #expect(shown(model, beta) == ["b1"])
        #expect(model.areSubagentsCollapsed(alpha))
        #expect(!model.areSubagentsCollapsed(beta))

        model.toggleSubagentsCollapsed(alpha)
        #expect(shown(model, alpha) == ["a1", "a2", "a3"])
    }

    @Test func aRowOffersTheDisclosureOnlyWhileItHasDispatches() {
        let model = model()
        #expect(model.hasSubagents(alpha))
        #expect(!model.hasSubagents(agent("gamma")))
    }

    @Test func aCollapsedParentCountsItsRunningDispatchesAtAnyDepth() {
        let model = model()
        #expect(model.runningSubagentCount(for: alpha) == 1, "queued and idle ones don't count")
        #expect(model.runningSubagentCount(for: beta) == 1)
        #expect(model.runningSubagentCount(for: agent("gamma")) == 0)
    }

    @Test func aStalledDispatchIsNotCountedAsRunning() {
        let stalled = LeoDispatch(id: "s1", status: "running", stalled: true)
        let model = LeoSidebarModel(snapshot: snapshot(["alpha": [(stalled, 0), (dispatch("a1"), 1)]]))
        #expect(model.runningSubagentCount(for: alpha) == 1)
    }

    @Test func collapsingDoesNotChangeTheParentsOwnState() {
        let model = model()
        let before = model.rows.first { $0.id == alpha.id }
        model.toggleSubagentsCollapsed(alpha)
        #expect(model.rows.first { $0.id == alpha.id } == before)
        #expect(model.rows.first { $0.id == alpha.id }?.activity == .working)
    }

    // MARK: Hide Subagents

    @Test func hideSubagentsCollapsesEveryAgentAndShowExpandsThemAll() {
        let model = model()
        model.toggleSubagentsCollapsed(alpha)

        model.toggleHideSubagents()
        #expect(model.hidesSubagents)
        #expect(shown(model, alpha).isEmpty && shown(model, beta).isEmpty)

        model.toggleHideSubagents()
        #expect(!model.hidesSubagents)
        #expect(shown(model, alpha) == ["a1", "a2", "a3"], "the earlier single collapse doesn't survive")
        #expect(shown(model, beta) == ["b1"])
    }

    @Test func anAgentCanBeReopenedWhileSubagentsAreHidden() {
        let model = model()
        model.toggleHideSubagents()
        model.toggleSubagentsCollapsed(beta)
        #expect(shown(model, beta) == ["b1"])
        #expect(shown(model, alpha).isEmpty)
    }

    @Test func agentsThatAppearLaterFollowTheHideSetting() {
        let model = model()
        model.toggleHideSubagents()
        model.receive(
            LeoSidebarSnapshot(
                rows: [alpha, beta, agent("gamma")], connectivity: .connected, generation: 2,
                dispatchChildren: ["gamma": [LeoDispatchNode(dispatch: dispatch("g1"), depth: 0)]],
                features: LeoDaemonFeatures(["dispatch_tree"])
            ),
            for: .local
        )
        #expect(shown(model, agent("gamma")).isEmpty)
    }

    // MARK: Selection

    @Test func collapsingTheParentOfTheSelectedDispatchSelectsTheAgent() {
        let model = model()
        model.userSelectedDispatch(LeoDispatchRef(host: .local, id: "b1"))
        #expect(model.selectedDispatch != nil)

        model.toggleSubagentsCollapsed(beta)

        #expect(model.selectedDispatch == nil)
        #expect(model.selection == beta.id)
    }

    @Test func hidingSubagentsSelectsTheAgentOfAHiddenSelectedDispatch() {
        let model = model()
        model.userSelectedDispatch(LeoDispatchRef(host: .local, id: "b1"))
        model.toggleHideSubagents()
        #expect(model.selectedDispatch == nil)
        #expect(model.selection == beta.id)
    }

    @Test func aCollapsedAgentsDispatchesAreNotNavigable() {
        let model = model()
        #expect(model.navigableItems(terminalIDs: []).contains(.dispatch(LeoDispatchRef(host: .local, id: "b1"))))
        model.toggleSubagentsCollapsed(beta)
        #expect(!model.navigableItems(terminalIDs: []).contains(.dispatch(LeoDispatchRef(host: .local, id: "b1"))))
    }

    // MARK: Persistence

    @Test func theChoicesSurviveARelaunch() {
        let store = LeoInMemorySidebarPreferencesStore()
        let first = model(store: store)
        first.toggleSubagentsCollapsed(alpha)

        let relaunched = model(store: store)
        #expect(relaunched.areSubagentsCollapsed(alpha))
        #expect(!relaunched.areSubagentsCollapsed(beta))

        relaunched.toggleHideSubagents()
        let again = model(store: store)
        #expect(again.hidesSubagents)
        #expect(again.areSubagentsCollapsed(alpha) && again.areSubagentsCollapsed(beta))
    }

    @Test func preferencesWithoutTheFieldsDecodeToExpanded() {
        let decoded = LeoSidebarPreferences.decode(Data(#"{"sortOrder":"name"}"#.utf8))
        #expect(!decoded.hidesSubagents)
        #expect(!decoded.isSubagentsCollapsed(alpha.id))
    }

    @Test func preferencesRoundTrip() {
        let preferences = LeoSidebarPreferences().togglingSubagents(of: alpha.id).settingHidesSubagents(true).togglingSubagents(of: beta.id)
        #expect(LeoSidebarPreferences.decode(preferences.encoded()) == preferences)
        #expect(preferences.isSubagentsCollapsed(alpha.id), "hidden, and Hide Subagents dropped its earlier toggle")
        #expect(!preferences.isSubagentsCollapsed(beta.id), "hidden by default, reopened by the exception")
        #expect(preferences.isSubagentsCollapsed(agent("gamma").id))
    }

    @Test func theRowsAccessibilityActionNamesWhatItWillDo() {
        #expect(LeoAgentRowContent.Subagents(isCollapsed: false, runningCount: 0, toggle: {}).actionName == "Hide Subagents")
        #expect(LeoAgentRowContent.Subagents(isCollapsed: true, runningCount: 2, toggle: {}).actionName == "Show Subagents")
    }

    // MARK: Menu

    @Test func theMenuTitleNamesWhatItWillDo() {
        #expect(LeoMenuCommands.hideSubagentsTitle(isHidden: false) == "Hide Subagents")
        #expect(LeoMenuCommands.hideSubagentsTitle(isHidden: true) == "Show Subagents")
    }

    /// ⌥⌘S: Ghostty's default keybinds use no ⌥⌘S, and no other menu item does.
    @Test func hideSubagentsLivesInTheViewMenuWithAShortcutNoOtherItemUses() throws {
        let items = try LeoMenuXib.shortcuts()
        let item = try #require(items.first { $0.action == "toggleLeoHideSubagents:" })
        #expect(item.title == "Hide Subagents")
        #expect(item.shortcut == "⌥⌘s")
        #expect(items.filter { $0.action != item.action && $0.shortcut == item.shortcut }.isEmpty)
        #expect(try LeoMenuXib.titles(forAction: "toggleLeoHideSubagents:") == ["Hide Subagents"])
    }
}
