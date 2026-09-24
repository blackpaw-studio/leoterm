import Foundation
import Testing

@testable import Ghostty

/// B-009: Agents ▸ Find Agent… and the sidebar filter's Escape/Return,
/// at the model/session level.
@MainActor struct LeoSidebarSearchTests {
    // MARK: Visible rows

    @Test func visibleRowsAreFuzzyRankedOverTheStatusOrder() {
        let model = makeModel([row("web-app", status: .stopped), row("apple"), row("a-p-p")])
        model.query = "app"
        #expect(model.visibleRows.map(\.name) == ["apple", "web-app", "a-p-p"])
    }

    @Test func visibleRowsKeepTheStatusOrderWithoutAQuery() {
        let model = makeModel([row("zed", status: .stopped), row("abc")])
        #expect(model.visibleRows.map(\.name) == ["abc", "zed"])
    }

    @Test func highlightsFollowTheQuery() {
        let model = makeModel([row("brand")])
        model.query = "bnd"
        #expect(model.searchHighlights(for: row("brand")) == [0, 3, 4])
        model.query = ""
        #expect(model.searchHighlights(for: row("brand")).isEmpty)
    }

    // MARK: Escape

    @Test func escapeWithTextClearsItAndKeepsFocus() {
        let model = makeModel([row("brand")])
        model.query = "bra"
        #expect(model.searchEscape() == .cleared)
        #expect(model.query.isEmpty)
    }

    @Test func escapeWithWhitespaceOnlyTextStillClearsIt() {
        let model = makeModel([row("brand")])
        model.query = "  "
        #expect(model.searchEscape() == .cleared)
        #expect(model.query.isEmpty)
    }

    @Test func escapeWhenEmptyLeavesTheField() {
        let model = makeModel([row("brand")])
        #expect(model.searchEscape() == .leaveField)
        #expect(model.query.isEmpty)
    }

    // MARK: Return

    @Test func returnSelectsTheTopRankedRowLikeAClick() {
        let model = makeModel([row("web-app"), row("apple")])
        model.query = "app"
        model.searchSubmit()
        #expect(model.selection == row("apple").id)
    }

    @Test func returnBringsAnExistingAttachForwardLikeAClick() {
        let apple = row("apple")
        let model = makeModel([apple])
        var focused: [String] = []
        model.focusExistingRequested = { focused.append($0.name) }
        model.receiveAttachLinks(LeoAttachLinkState(focused: nil, tabCounts: [apple.id: 1]))
        model.query = "app"

        model.searchSubmit()

        #expect(focused == ["apple"])
    }

    @Test func returnNeverAttachesANewSession() {
        let model = makeModel([row("apple")])
        var attached = 0
        model.attachRequested = { _, _, _ in attached += 1 }
        model.query = "app"
        model.searchSubmit()
        #expect(attached == 0)
    }

    @Test func returnWithNoMatchesDoesNothing() {
        let model = makeModel([row("apple")])
        model.selection = row("apple").id
        model.query = "zzz"
        model.searchSubmit()
        #expect(model.selection == row("apple").id)
    }

    @Test func returnIsInertWhileDisconnected() {
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(
            rows: [row("apple")],
            connectivity: .disconnected(reason: "gone", isRetrying: false),
            generation: 1))
        model.query = "app"
        model.searchSubmit()
        #expect(model.selection == nil)
    }

    // MARK: Find Agent… (session + menu)

    @Test func findAgentShowsAHiddenSidebarAndRequestsFocus() {
        let session = makeSession(sidebarVisible: false)
        let before = session.searchFocusRequest
        session.requestSearchFocus()
        #expect(session.isSidebarVisible)
        #expect(session.searchFocusRequest == before + 1)
    }

    @Test func findAgentOnAVisibleSidebarStillRequestsFocusEachTime() {
        let session = makeSession(sidebarVisible: true)
        session.requestSearchFocus()
        session.requestSearchFocus()
        #expect(session.isSidebarVisible)
        #expect(session.searchFocusRequest == 2)
    }

    @Test func findAgentMenuItemEnablement() {
        #expect(!LeoMenuCommands.canFindAgent(hasLeoSession: false, isSidebarVisible: true, showingSqueezesTerminal: false))
        #expect(LeoMenuCommands.canFindAgent(hasLeoSession: true, isSidebarVisible: false, showingSqueezesTerminal: false))
        #expect(LeoMenuCommands.canFindAgent(hasLeoSession: true, isSidebarVisible: true, showingSqueezesTerminal: true))
        // D-059: never squeeze the terminal under its floor to show it.
        #expect(!LeoMenuCommands.canFindAgent(hasLeoSession: true, isSidebarVisible: false, showingSqueezesTerminal: true))
    }

    private func makeModel(_ rows: [LeoAgentRow]) -> LeoSidebarModel {
        LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: rows, connectivity: .connected, generation: 1))
    }

    private func makeSession(sidebarVisible: Bool) -> LeoWindowSession {
        let suite = "LeoSidebarSearchTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(sidebarVisible, forKey: "leo.sidebarVisible")
        return LeoWindowSession(defaults: defaults)
    }

    private func row(_ name: String, status: LeoAgentStatus = .running) -> LeoAgentRow {
        LeoAgentRow(host: .local, name: name, template: nil, status: status, activity: .idle, actionDetail: nil)
    }
}
