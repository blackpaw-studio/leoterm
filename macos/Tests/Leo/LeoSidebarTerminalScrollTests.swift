import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// B-057: the Terminals section sits below every agent, so a terminal row
/// the window selects -- a new one ⌘T just added, or one it switched to --
/// is scrolled into view, through the real list. The sidebar's window is
/// shown but never made key.
@MainActor @Suite(.serialized)
struct LeoSidebarTerminalScrollTests {
    private static let agentCount = 40

    @Test(arguments: ["a new row", "a listed row"])
    func aSelectedTerminalRowBelowManyAgentsIsScrolledIntoView(_ selected: String) async throws {
        let terminals = LeoWindowTerminals()
        let listed = UUID()
        if selected == "a listed row" { terminals.add(listed, title: "Terminal") }
        let window = try makeWindow(terminals: terminals)
        defer { window.close() }
        let table = try await settledTable(in: window)
        let rowsBefore = table.numberOfRows
        try #require(!isVisible(row: rowsBefore - 1, in: table), "the list starts scrolled to its top")

        if selected == "a new row" {
            // As ⌘T does: added and selected in the same turn.
            let id = UUID()
            terminals.add(id, title: "Terminal")
            terminals.select(id)
        } else {
            terminals.select(listed)
        }

        _ = await eventually { table.numberOfRows > rowsBefore || selected == "a listed row" }
        let row = table.numberOfRows - 1
        #expect(await eventually { isVisible(row: row, in: table) }, "the selected terminal row is on screen")
    }

    /// B-067, on a long list whose Terminals section already shows a row
    /// at the bottom edge: a new row selected one further down is revealed
    /// whole, not left cut off there -- whether it's added and selected in
    /// the same turn (as ⌘T does) or a later one (as the attach host does).
    /// A guard, not a reproduction: both cases passed before B-067's
    /// reveal (checked again in B-078); the filter cases below are the
    /// ones it fixed.
    @Test(arguments: ["the same turn", "a later turn"])
    func aNewRowBelowAListedOneIsRevealedWhole(_ selectedIn: String) async throws {
        let terminals = LeoWindowTerminals()
        let listed = UUID()
        terminals.add(listed, title: "Terminal")
        let window = try makeWindow(terminals: terminals)
        defer { window.close() }
        let table = try await settledTable(in: window)
        terminals.select(listed)
        try #require(await eventually { isVisible(row: table.numberOfRows - 1, in: table) }, "the listed row is on screen")
        let rowsBefore = table.numberOfRows

        let id = UUID()
        terminals.add(id, title: "Terminal")
        if selectedIn == "a later turn" {
            // As the attach host does: the row lists, then its shell shows.
            try #require(await eventually { table.numberOfRows > rowsBefore }, "the new row lists")
        }
        terminals.select(id)

        #expect(await eventually { table.numberOfRows > rowsBefore && isVisible(row: table.numberOfRows - 1, in: table) },
                "the new terminal row is wholly on screen")
    }

    /// B-067: the filter hides the Terminals section, so a row selected
    /// meanwhile (⌘T with a search still in the field) is revealed once
    /// the filter clears -- as Mail reveals its selection after a search.
    /// B-099: counts run-loop turns, not time. The "no-such-agent" case
    /// flaked while "No matches" replaced the list: clearing the filter
    /// built a new one, whose first-appearance reveal could run before it
    /// had its rows.
    @Test(arguments: ["agent-1", "no-such-agent"])
    func aRowSelectedWhileFilteredIsRevealedWhenTheFilterClears(_ query: String) async throws {
        let terminals = LeoWindowTerminals()
        let (window, model) = try makeWindowAndModel(terminals: terminals)
        defer { window.close() }
        _ = try await settledTable(in: window)
        model.query = query
        let id = UUID()
        terminals.add(id, title: "Terminal")
        terminals.select(id)
        await afterPendingUpdates()
        try #require((tables(in: window.contentView).first?.numberOfRows ?? 0) <= Self.agentCount, "the filter hides the Terminals section")

        model.query = ""
        await afterPendingUpdates()

        let table = try #require(tables(in: window.contentView).first)
        #expect(table.numberOfRows > Self.agentCount && isVisible(row: table.numberOfRows - 1, in: table),
                "the selected terminal row is on screen once the Terminals section shows again")
    }

    /// B-099: a filter that matches no agent leaves the list in place,
    /// empty under "No matches", instead of swapping it for another view,
    /// so the same list comes back when the filter clears.
    @Test func aFilterWithNoMatchesKeepsTheListInPlace() async throws {
        let (window, model) = try makeWindowAndModel(terminals: LeoWindowTerminals())
        defer { window.close() }
        let table = try await settledTable(in: window)

        model.query = "no-such-agent"
        await afterPendingUpdates()

        #expect(tables(in: window.contentView).first === table, "the list stays while nothing matches")
        #expect(table.numberOfRows == 0, "the list is empty")

        model.query = ""
        await afterPendingUpdates()

        #expect(tables(in: window.contentView).first === table, "the same list is back")
        #expect((tables(in: window.contentView).first?.numberOfRows ?? 0) > Self.agentCount, "it lists the agents again")
    }

    /// B-099 (D-129): a terminal row selected while the agents are still
    /// loading is revealed once they list above it and push it down, in
    /// the same list. Only the scroll down to it is required, not the row
    /// wholly on screen: here the list also grows into the space Loading
    /// had, and the reveal can land before AppKit lays that out (see
    /// `LeoTerminalRowReveal.reveal`).
    @Test func aRowSelectedWhileLoadingIsRevealedWhenTheAgentsList() async throws {
        let terminals = LeoWindowTerminals()
        let id = UUID()
        terminals.add(id, title: "Terminal")
        terminals.select(id)
        let (window, model) = try makeWindowAndModel(
            terminals: terminals, snapshot: LeoSidebarSnapshot(rows: [], connectivity: .loading, generation: 1)
        )
        defer { window.close() }
        // The Terminals header and its row.
        let table = try await settledTable(in: window, moreThan: 1)

        model.receive(LeoSidebarSnapshot(rows: Self.agents(count: Self.agentCount), connectivity: .connected, generation: 2))
        await afterPendingUpdates()

        try #require(tables(in: window.contentView).first === table, "the same list takes the agents")
        try #require(table.numberOfRows > Self.agentCount, "the agents list above the row")
        #expect(table.visibleRect.minY > 0, "the list scrolls down to the selected terminal row")
    }

    /// B-078 (D-130): with the selected terminal row scrolled away (the
    /// user went up to the agents), its shell retitling or the agent list
    /// refreshing leaves the list where the user put it.
    @Test(arguments: ["a retitle", "an agent refresh"])
    func aRetitleOrRefreshLeavesTheScrollOffsetAlone(_ change: String) async throws {
        let terminals = LeoWindowTerminals()
        let selected = UUID()
        terminals.add(selected, title: "Terminal")
        let (window, model) = try makeWindowAndModel(terminals: terminals)
        defer { window.close() }
        let table = try await settledTable(in: window)
        terminals.select(selected)
        try #require(await eventually { isVisible(row: table.numberOfRows - 1, in: table) }, "the selected row is revealed")
        table.scrollRowToVisible(0)
        await afterPendingUpdates()
        try #require(!isVisible(row: table.numberOfRows - 1, in: table), "the selected row is scrolled away")
        let offset = table.visibleRect.minY
        let rowsBefore = table.numberOfRows

        if change == "a retitle" {
            terminals.retitle(selected, to: "vim notes.md")
        } else {
            // One more agent, so the refresh shows in the list.
            model.receive(LeoSidebarSnapshot(rows: Self.agents(count: Self.agentCount + 1), connectivity: .connected, generation: 2))
            try #require(await eventually { table.numberOfRows > rowsBefore }, "the refresh lists")
        }
        await afterPendingUpdates()

        #expect(table.visibleRect.minY == offset, "the list stays where it was")
    }

    /// B-078 (D-130): selecting a row that's already wholly on screen
    /// doesn't move the list, even when the row isn't at an edge.
    @Test func selectingARowAlreadyOnScreenDoesNotScroll() async throws {
        let terminals = LeoWindowTerminals()
        let first = UUID()
        let second = UUID()
        terminals.add(first, title: "Terminal")
        terminals.add(second, title: "Terminal")
        let window = try makeWindow(terminals: terminals)
        defer { window.close() }
        let table = try await settledTable(in: window)
        terminals.select(second)
        let lastRow = table.numberOfRows - 1
        try #require(await eventually { isVisible(row: lastRow, in: table) }, "the second row is revealed")
        // Up by half a row: the first row stays wholly on screen, clear
        // of the bottom edge, and the second is cut off there.
        let halfRow = (table.rect(ofRow: lastRow).height / 2).rounded()
        table.scroll(NSPoint(x: table.visibleRect.minX, y: table.visibleRect.minY - halfRow))
        await afterPendingUpdates()
        let firstRow = lastRow - 1
        try #require(isVisible(row: firstRow, in: table) && !isVisible(row: lastRow, in: table), "the first row is on screen, the second cut off")
        try #require(table.rect(ofRow: firstRow).maxY < table.visibleRect.maxY - 1, "the first row isn't at the bottom edge")
        let offset = table.visibleRect.minY

        terminals.select(first)
        try #require(await eventually { table.selectedRow == firstRow }, "the list selects the first row")
        await afterPendingUpdates()

        #expect(table.visibleRect.minY == offset, "the list doesn't move")
    }

    /// B-081: the window's last terminal row closes while it's revealed at
    /// the bottom of a long list. The section goes, and the list lands on
    /// the window's selection (the agent it falls back to), or its top
    /// when nothing is selected -- not wherever the section's removal
    /// left it.
    @Test(arguments: ["the selected agent", "the top"])
    func closingTheLastRowLandsOnTheSelectionOrTheTop(_ landing: String) async throws {
        let terminals = LeoWindowTerminals()
        let (window, model) = try makeWindowAndModel(terminals: terminals)
        defer { window.close() }
        let table = try await settledTable(in: window)
        if landing == "the selected agent" { model.userSelected(Self.agents(count: Self.agentCount)[0].id) }
        let shell = try await revealedLastRow(in: table, terminals: terminals)
        let rowsBefore = table.numberOfRows

        terminals.remove(shell)
        await afterPendingUpdates()

        try #require(table.numberOfRows < rowsBefore, "the Terminals section is gone")
        if landing == "the selected agent" {
            let selected = table.selectedRow
            try #require(selected >= 0, "the list selects the agent")
            #expect(isVisible(row: selected, in: table), "the selected agent row is on screen")
        } else {
            #expect(isVisible(row: 0, in: table), "the list is at its top")
        }
    }

    /// B-081 (D-130): a selected agent that's already on screen once the
    /// section goes keeps its place: the list doesn't move to it or to
    /// the top. A guard: the list already stayed put before B-081.
    @Test func closingTheLastRowLeavesASelectionOnScreenWhereItIs() async throws {
        let terminals = LeoWindowTerminals()
        let (window, model) = try makeWindowAndModel(terminals: terminals)
        defer { window.close() }
        let table = try await settledTable(in: window)
        // The last agent: right above the Terminals section.
        model.userSelected(Self.agents(count: Self.agentCount)[Self.agentCount - 1].id)
        let shell = try await revealedLastRow(in: table, terminals: terminals)

        terminals.remove(shell)
        await afterPendingUpdates()

        let selected = table.selectedRow
        try #require(selected >= 0, "the list selects the agent")
        #expect(isVisible(row: selected, in: table), "the selected agent row is on screen")
        #expect(abs(table.visibleRect.maxY - table.bounds.maxY) <= 1, "the list stays at its bottom, where the selection shows")
    }

    /// A new terminal row, selected and revealed at the bottom of the list
    /// (as ⌘T leaves it).
    private func revealedLastRow(in table: NSTableView, terminals: LeoWindowTerminals) async throws -> UUID {
        let rowsBefore = table.numberOfRows
        let id = UUID()
        terminals.add(id, title: "Terminal")
        terminals.select(id)
        await afterPendingUpdates()
        try #require(table.numberOfRows > rowsBefore && isVisible(row: table.numberOfRows - 1, in: table), "the row is revealed")
        try #require(!isVisible(row: 0, in: table), "the list is scrolled away from its top")
        return id
    }

    private func makeWindow(terminals: LeoWindowTerminals) throws -> NSWindow {
        try makeWindowAndModel(terminals: terminals).window
    }

    /// `snapshot` defaults to the connected list of `agentCount` agents.
    private func makeWindowAndModel(
        terminals: LeoWindowTerminals, snapshot: LeoSidebarSnapshot? = nil
    ) throws -> (window: NSWindow, model: LeoSidebarModel) {
        let model = LeoSidebarModel(
            snapshot: snapshot ?? LeoSidebarSnapshot(rows: Self.agents(count: Self.agentCount), connectivity: .connected, generation: 1)
        )
        let actions = LeoAgentActions(
            daemon: ScrollTestDaemon(), cli: LeoCLI(), model: model, hostSelection: .isolatedForTesting(), refresh: {}
        )
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 320, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: LeoSidebarView(model: model, windowID: LeoWindowID(), actions: actions, terminals: terminals)
        )
        window.orderFront(nil)
        return (window, model)
    }

    /// Like a real list: rows of mixed heights (a template adds a
    /// subtitle line) in more than one section.
    private static func agents(count: Int) -> [LeoAgentRow] {
        (0 ..< count).map {
            LeoAgentRow(
                host: .local, name: "agent-\($0)", template: $0.isMultiple(of: 3) ? nil : "claude",
                status: $0 < agentCount / 2 ? .running : .stopped, activity: .idle, actionDetail: nil
            )
        }
    }

    /// Lets the main run loop turn a few times, so whatever a change
    /// prompts has landed: SwiftUI applies it on a later turn, and a reveal
    /// runs a turn after that. Counts turns, not time.
    private func afterPendingUpdates(turns: Int = 5) async {
        for _ in 0 ..< turns {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    /// The whole row (to within a point) is within what the list's scroll
    /// view shows: a row cut off at an edge isn't revealed.
    private func isVisible(row: Int, in table: NSTableView) -> Bool {
        guard row >= 0, row < table.numberOfRows else { return false }
        let rect = table.rect(ofRow: row).insetBy(dx: 0, dy: 1)
        return table.visibleRect.contains(rect)
    }

    /// The window's list once it first fills: more than `rows` rows (by
    /// default, more than the agents alone).
    private func settledTable(in window: NSWindow, moreThan rows: Int = Self.agentCount) async throws -> NSTableView {
        _ = await eventually { tables(in: window.contentView).first.map { $0.numberOfRows > rows } ?? false }
        return try #require(tables(in: window.contentView).first)
    }

    private func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func tables(in view: NSView?) -> [NSTableView] {
        guard let view else { return [] }
        return (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
    }
}

private struct ScrollTestDaemon: LeoDaemonClient {
    func listAgents() async throws -> [LeoAgent] { [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func start(_ name: String) async throws { throw LeoDaemonError.transport("unused") }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { throw LeoDaemonError.transport("unused") }
    func restart(_ name: String) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func reset(_ name: String) async throws { throw LeoDaemonError.transport("unused") }
    func setTemplate(_ name: String, template: String) async throws { throw LeoDaemonError.transport("unused") }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { throw LeoDaemonError.transport("unused") }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { throw LeoDaemonError.transport("unused") }
    func logs(_ name: String, lines: Int?) async throws -> String { throw LeoDaemonError.transport("unused") }
}
