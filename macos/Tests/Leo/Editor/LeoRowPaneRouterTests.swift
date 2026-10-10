import Foundation
import Testing

@testable import Ghostty

/// B-274: an action on agent row A (Browse Files, Open Surfaced File) fills
/// A's own pane in the window that shows A, and never the pane of the row
/// on screen.
@MainActor
struct LeoRowPaneRouterTests {
    private static let shownKey = LeoRowKey.agent(LeoAgentIdentity(host: .local, name: "beta"))

    private func row(_ status: LeoAgentStatus) -> LeoAgentRow {
        LeoAgentRow(host: .local, name: "alpha", template: "default", status: status, activity: .unknown, actionDetail: nil)
    }

    private func session(showing key: LeoRowKey = shownKey) -> LeoWindowSession {
        let session = LeoWindowSession(defaults: LeoInMemoryDefaults())
        session.panes.activate(key)
        return session
    }

    @Test func aStoppedAgentsActionFillsItsOwnPaneNotTheShownRows() async throws {
        let origin = session()
        let shown = origin.panes.active
        var shows = 0
        let router = LeoRowPaneRouter(show: { _, _ in shows += 1; return nil }, session: { _ in nil })

        let target = try #require(await router.pane(for: row(.stopped), from: origin))

        #expect(target.session === origin)
        #expect(target.pane !== shown, "the row on screen keeps its pane")
        #expect(target.pane === origin.panes.existingPane(for: .agent(row(.stopped).identity)))
        #expect(origin.panes.active === shown)
        #expect(shows == 0, "a stopped agent isn't shown without asking to start it")
    }

    @Test func anAgentShownInAnotherWindowFillsThatWindowsPane() async throws {
        let origin = session()
        let other = session(showing: .agent(row(.running).identity))
        let router = LeoRowPaneRouter(show: { _, _ in other.id }, session: { $0 == other.id ? other : origin })

        let target = try #require(await router.pane(for: row(.running), from: origin))

        #expect(target.session === other)
        #expect(target.pane === other.panes.active)
        #expect(origin.panes.existingPane(for: .agent(row(.running).identity)) == nil, "nothing is filled in the window left behind")
    }

    @Test func aShowThatDidNotHappenFillsNothing() async {
        let origin = session()
        let router = LeoRowPaneRouter(show: { _, _ in nil }, session: { _ in origin })

        let target = await router.pane(for: row(.running), from: origin)

        #expect(target == nil)
        #expect(origin.panes.existingPane(for: .agent(row(.running).identity)) == nil)
    }
}
