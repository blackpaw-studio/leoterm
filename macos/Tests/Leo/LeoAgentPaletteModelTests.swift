import Foundation
import Testing

@testable import Ghostty

@MainActor struct LeoAgentPaletteModelTests {
    private func row(_ name: String, host: LeoHostID = .local, status: LeoAgentStatus = .running, repo: String? = nil) -> LeoAgentRow {
        LeoAgentRow(host: host, name: name, template: nil, status: status, activity: .idle, actionDetail: nil, repo: repo)
    }

    private func snapshot(_ rows: [LeoAgentRow]) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(rows: rows, connectivity: .connected, generation: 0)
    }

    @Test func agentsAreRankedLikeSidebarWithNewAgentAndPlainShellLast() {
        let model = LeoAgentPaletteModel()
        model.update(
            snapshot: snapshot([row("zed", status: .stopped), row("alpha", status: .running)]),
            selectedHost: .local,
            hostState: .connected(socketPath: "/tmp/leo.sock")
        )

        #expect(model.rows == [.agent(row("alpha", status: .running)), .agent(row("zed", status: .stopped)), .newAgent, .plainShell])
    }

    @Test func filterMatchesNameOrRepoCaseInsensitive() {
        let model = LeoAgentPaletteModel()
        model.update(
            snapshot: snapshot([row("worker", repo: "leoterm"), row("other", repo: "ghostty")]),
            selectedHost: .local,
            hostState: .connected(socketPath: "/tmp/leo.sock")
        )

        model.filterText = "LEO"
        #expect(model.rows == [.agent(row("worker", repo: "leoterm")), .newAgent, .plainShell])

        model.filterText = "WORK"
        #expect(model.rows == [.agent(row("worker", repo: "leoterm")), .newAgent, .plainShell])

        model.filterText = "nomatch"
        #expect(model.rows == [.newAgent, .plainShell])

        // Clearing the filter must land selection back on row 0 (the first
        // agent, ranked alphabetically -- "other" before "worker"), not
        // wherever the last filtered list happened to leave it.
        model.filterText = ""
        #expect(model.confirm() == .agent(row("other", repo: "ghostty").identity))
    }

    // MARK: B-042 -- the sidebar's fuzzy matcher

    private func connected(_ rows: [LeoAgentRow]) -> LeoAgentPaletteModel {
        let model = LeoAgentPaletteModel()
        model.update(snapshot: snapshot(rows), selectedHost: .local, hostState: .connected(socketPath: "/tmp/leo.sock"))
        return model
    }

    @Test func filterMatchesInOrderLettersLikeTheSidebar() {
        let model = connected([row("leo-home-assistant"), row("olympus")])

        model.filterText = "lha"

        #expect(model.rows == [.agent(row("leo-home-assistant")), .newAgent, .plainShell])
    }

    @Test func filterRanksBetterShapedMatchesFirstAndReturnTakesTheTop() {
        // Alphabetical (the unfiltered order) would put "alpha-leo" first.
        let model = connected([row("alpha-leo"), row("leo"), row("leoterm"), row("lxexo")])

        model.filterText = "leo"

        #expect(model.rows == [
            .agent(row("leo")), .agent(row("leoterm")), .agent(row("alpha-leo")), .agent(row("lxexo")),
            .newAgent, .plainShell,
        ])
        #expect(model.confirm() == .agent(row("leo").identity))
    }

    @Test func filterStillMatchesRepoButANameMatchRanksFirst() {
        let model = connected([row("alpha", repo: "worker"), row("worker", repo: "ghostty")])

        model.filterText = "worker"

        #expect(model.rows == [
            .agent(row("worker", repo: "ghostty")), .agent(row("alpha", repo: "worker")), .newAgent, .plainShell,
        ])
    }

    @Test func filterFoldsNonASCIICase() {
        let model = connected([row("Straße"), row("other")])

        model.filterText = "STRASSE"

        #expect(model.rows == [.agent(row("Straße")), .newAgent, .plainShell])
    }

    @Test func nameHighlightsBoldTheMatchedLetters() {
        let model = connected([row("leo-home-assistant", repo: "lha")])

        #expect(model.nameHighlights(for: row("leo-home-assistant", repo: "lha")).isEmpty)
        model.filterText = " lha "
        #expect(model.nameHighlights(for: row("leo-home-assistant", repo: "lha")) == [0, 4, 9])
    }

    @Test func hostIsolationOnlyShowsSelectedHostAgents() {
        let model = LeoAgentPaletteModel()
        model.update(
            snapshot: snapshot([row("here", host: .local), row("there", host: .remote("work"))]),
            selectedHost: .local,
            hostState: .connected(socketPath: "/tmp/leo.sock")
        )

        #expect(model.rows == [.agent(row("here", host: .local)), .newAgent, .plainShell])
    }

    @Test func selectionIsPreservedAcrossRefreshByStableIdentity() {
        let model = LeoAgentPaletteModel()
        model.update(snapshot: snapshot([row("alpha"), row("beta")]), selectedHost: .local, hostState: .connected(socketPath: "/tmp/leo.sock"))
        model.moveSelection(by: 1)
        #expect(model.confirm() == .agent(row("beta").identity))

        model.update(snapshot: snapshot([row("alpha"), row("beta"), row("gamma")]), selectedHost: .local, hostState: .connected(socketPath: "/tmp/leo.sock"))
        #expect(model.confirm() == .agent(row("beta").identity))
    }

    @Test func selectionClampsWhenSelectedAgentIsRemoved() {
        let model = LeoAgentPaletteModel()
        model.update(snapshot: snapshot([row("alpha"), row("beta")]), selectedHost: .local, hostState: .connected(socketPath: "/tmp/leo.sock"))
        model.moveSelection(by: 1)
        #expect(model.confirm() == .agent(row("beta").identity))

        model.update(snapshot: snapshot([row("alpha")]), selectedHost: .local, hostState: .connected(socketPath: "/tmp/leo.sock"))
        #expect(model.confirm() == .newAgent)
    }

    @Test func connectingReplacesAgentRowsWithStatusAndDisablesNewAgent() {
        let model = LeoAgentPaletteModel()
        model.update(snapshot: snapshot([row("alpha")]), selectedHost: .remote("work"), hostState: .connecting)

        #expect(model.rows == [.status(text: "Connecting to work…", hint: nil, canRetry: false), .newAgent, .plainShell])
        model.moveSelection(by: 1)
        #expect(model.confirm() == nil)
        model.moveSelection(by: 1)
        #expect(model.confirm() == .plainShell)
    }

    @Test func failedShowsMessageHintAndAllowsRetryButNotNewAgent() {
        var retried = false
        let model = LeoAgentPaletteModel(retry: { retried = true })
        model.update(
            snapshot: snapshot([row("alpha")]),
            selectedHost: .remote("work"),
            hostState: .failed(message: "Connection refused", hint: "Check the host is reachable")
        )

        #expect(model.rows == [.status(text: "Connection refused", hint: "Check the host is reachable", canRetry: true), .newAgent, .plainShell])
        #expect(model.confirm() == nil)
        model.moveSelection(by: 1)
        #expect(model.confirm() == nil)

        model.retryConnection()
        #expect(retried)
    }

    @Test func cancelAlwaysReturnsCancelChoiceRegardlessOfSelection() {
        let model = LeoAgentPaletteModel()
        model.update(snapshot: snapshot([row("alpha")]), selectedHost: .local, hostState: .connected(socketPath: "/tmp/leo.sock"))
        #expect(model.cancel() == .cancel)
    }

    /// Selection defaults to the status row (index 0) while connecting --
    /// that row is never confirmable, so Return (`confirm()`) must do
    /// nothing rather than resolving to some other row.
    @Test func confirmWithNoConfirmableRowDoesNothing() {
        let model = LeoAgentPaletteModel()
        model.update(snapshot: snapshot([]), selectedHost: .remote("work"), hostState: .connecting)

        #expect(model.confirm() == nil)
    }

    /// With a large agent list, setting `filterText` to a needle that
    /// matches exactly one agent (not the first alphabetically) must select
    /// that agent -- not fall back to the preserved "New agent…" selection,
    /// which only applies to unchanged-filter snapshot refreshes.
    @Test func filterTextChangeSelectsFirstMatchingAgentEvenWithManyRows() {
        let model = LeoAgentPaletteModel()
        let rows = (0..<100).map { row("agent-\($0)") } + [row("leoterm-worker")]
        model.update(snapshot: snapshot(rows), selectedHost: .local, hostState: .connected(socketPath: "/tmp/leo.sock"))

        // Default selection sits on the first row (an "agent-*" row).
        #expect(model.confirm() == .agent(row("agent-0").identity))

        model.filterText = "leoterm"
        #expect(model.confirm() == .agent(row("leoterm-worker").identity))
    }

    @Test func moveSelectionClampsAtBounds() {
        let model = LeoAgentPaletteModel()
        model.update(snapshot: snapshot([row("alpha")]), selectedHost: .local, hostState: .connected(socketPath: "/tmp/leo.sock"))
        model.moveSelection(by: -5)
        #expect(model.confirm() == .agent(row("alpha").identity))
        model.moveSelection(by: 5)
        #expect(model.confirm() == .plainShell)
        model.moveSelection(by: 5)
        #expect(model.confirm() == .plainShell)
    }
}
