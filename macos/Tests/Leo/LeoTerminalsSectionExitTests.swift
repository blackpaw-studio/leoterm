import Testing

@testable import Ghostty

/// B-081: where the sidebar list lands once the window's last terminal row
/// closes -- the selected agent's row if it's listed, else the top.
@MainActor struct LeoTerminalsSectionExitTests {
    private static func row(_ name: String) -> LeoAgentRow {
        LeoAgentRow(host: .local, name: name, template: nil, status: .running, activity: .idle, actionDetail: nil)
    }

    private static var running: LeoSidebarSection { LeoSidebarSection(id: "running", title: "Running", rows: [row("a"), row("b")]) }
    private static var stopped: LeoSidebarSection { LeoSidebarSection(id: "stopped", title: "Stopped", rows: [row("c")]) }
    private static var top: LeoTerminalsSectionExit.Landing { .section(LeoSidebarSectionAnchor(sectionID: "running")) }

    @Test func aListedSelectedAgentIsTheLanding() {
        let landing = LeoTerminalsSectionExit.landing(selectedAgent: Self.row("c").id, in: [Self.running, Self.stopped])
        #expect(landing == .row(.agent(Self.row("c").id)))
    }

    @Test func withNoSelectedAgentTheListLandsOnItsTop() {
        #expect(LeoTerminalsSectionExit.landing(selectedAgent: nil, in: [Self.running, Self.stopped]) == Self.top)
    }

    /// A collapsed section lists no rows, so there's nothing to reveal.
    @Test func aSelectedAgentInACollapsedSectionLandsOnTheTop() {
        let collapsed = LeoSidebarSection(id: "stopped", title: "Stopped", rows: [Self.row("c")], isCollapsed: true)
        #expect(LeoTerminalsSectionExit.landing(selectedAgent: Self.row("c").id, in: [Self.running, collapsed]) == Self.top)
    }

    /// Filtered away or gone from the list.
    @Test func anUnlistedSelectedAgentLandsOnTheTop() {
        #expect(LeoTerminalsSectionExit.landing(selectedAgent: Self.row("z").id, in: [Self.running]) == Self.top)
    }

    @Test func withNoSectionsThereIsNoLanding() {
        #expect(LeoTerminalsSectionExit.landing(selectedAgent: Self.row("a").id, in: []) == nil)
    }
}
