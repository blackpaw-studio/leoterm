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

        await afterPendingUpdates()

        try #require(table.numberOfRows > rowsBefore || selected == "a listed row", "the new row lists")
        #expect(isVisible(row: table.numberOfRows - 1, in: table), "the selected terminal row is on screen")
    }

    /// On a long list whose Terminals section already shows a row at the
    /// bottom edge, a new row selected one further down is revealed whole,
    /// not left cut off there -- whether it's added and selected in the
    /// same turn (as ⌘T does) or a later one (as the attach host does).
    /// The list's own minimal scroll does this; D-129's reveals, when the
    /// filter clears or the list reappears, are the cases below.
    @Test(arguments: ["the same turn", "a later turn"])
    func aNewRowBelowAListedOneIsRevealedWhole(_ selectedIn: String) async throws {
        let terminals = LeoWindowTerminals()
        let listed = UUID()
        terminals.add(listed, title: "Terminal")
        let window = try makeWindow(terminals: terminals)
        defer { window.close() }
        let table = try await settledTable(in: window)
        terminals.select(listed)
        await afterPendingUpdates()
        try #require(isVisible(row: table.numberOfRows - 1, in: table), "the listed row is on screen")
        let rowsBefore = table.numberOfRows

        let id = UUID()
        terminals.add(id, title: "Terminal")
        if selectedIn == "a later turn" {
            // As the attach host does: the row lists, then its shell shows.
            await afterPendingUpdates()
            try #require(table.numberOfRows > rowsBefore, "the new row lists")
        }
        terminals.select(id)
        await afterPendingUpdates()

        #expect(table.numberOfRows > rowsBefore && isVisible(row: table.numberOfRows - 1, in: table),
                "the new terminal row is wholly on screen")
    }

    /// D-129: the filter hides the Terminals section, so a row selected
    /// meanwhile (⌘T with a search still in the field) is revealed once
    /// the filter clears -- as Mail reveals its selection after a search.
    /// With "no-such-agent" the list empties under "No matches" and fills
    /// again, so the reveal follows the list's own change, not a new
    /// list's first appearance (which can run before it has its rows).
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

    /// D-129, the list reappearing: a terminal row selected while the
    /// agents are still loading is revealed once they list above it and
    /// push it down, in the same list. Only the scroll down to it is
    /// required, not the row wholly on screen: here the list also grows
    /// into the space Loading had, and the reveal can land before AppKit
    /// lays that out (see `LeoTerminalRowReveal.reveal`).
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
    /// refreshing leaves the list where the user put it: the same list, at
    /// the same offset. Parked mid-list, so a jump to the top shows too.
    @Test(arguments: ["a retitle", "an agent refresh"])
    func aRetitleOrRefreshLeavesTheScrollOffsetAlone(_ change: String) async throws {
        let terminals = LeoWindowTerminals()
        let selected = UUID()
        terminals.add(selected, title: "Terminal")
        let (window, model) = try makeWindowAndModel(terminals: terminals)
        defer { window.close() }
        let table = try await settledTable(in: window)
        terminals.select(selected)
        await afterPendingUpdates()
        let selectedRow = table.numberOfRows - 1
        try #require(isVisible(row: selectedRow, in: table), "the selected row is revealed")
        // Mid-list: an agent halfway down at the top edge.
        table.scroll(NSPoint(x: table.visibleRect.minX, y: table.rect(ofRow: Self.agentCount / 2).minY))
        await afterPendingUpdates()
        try #require(!isVisible(row: 0, in: table) && !isVisible(row: selectedRow, in: table),
                     "the list is parked between its top and the selected row")
        let offset = table.visibleRect.minY
        let rowsBefore = table.numberOfRows

        // The window's list, whichever it is: a rebuilt one shows the
        // change too, and the identity check below names it.
        let list = { tables(in: window.contentView).first }
        if change == "a retitle" {
            let titleEnd = try #require(drawingEnd(ofRow: selectedRow, in: table), "the row draws its title")
            terminals.retitle(selected, to: "vim notes.md")
            // The new title is longer, so the row draws further right.
            let drawnEnd = { list().flatMap { drawingEnd(ofRow: selectedRow, in: $0) } ?? 0 }
            try #require(await turns { drawnEnd() > titleEnd }, "the row draws its new title: it ended at \(titleEnd), now \(drawnEnd())")
        } else {
            // One more agent, so the refresh shows in the list.
            model.receive(LeoSidebarSnapshot(rows: Self.agents(count: Self.agentCount + 1), connectivity: .connected, generation: 2))
            try #require(await turns { (list()?.numberOfRows ?? 0) > rowsBefore }, "the refresh lists")
        }
        await afterPendingUpdates()

        #expect(list() === table, "the list is the same one")
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
        await afterPendingUpdates()
        try #require(isVisible(row: lastRow, in: table), "the second row is revealed")
        // Up by half a row: the first row stays wholly on screen, clear
        // of the bottom edge, and the second is cut off there.
        let halfRow = (table.rect(ofRow: lastRow).height / 2).rounded()
        table.scroll(NSPoint(x: table.visibleRect.minX, y: table.visibleRect.minY - halfRow))
        await afterPendingUpdates()
        let firstRow = lastRow - 1
        try #require(isVisible(row: firstRow, in: table) && !isVisible(row: lastRow, in: table), "the first row is on screen, the second cut off")
        try #require(table.rect(ofRow: firstRow).maxY < table.visibleRect.maxY - 1, "the first row isn't at the bottom edge")
        try #require(!isVisible(row: 0, in: table), "the list is scrolled away from its top")
        let offset = table.visibleRect.minY

        terminals.select(first)
        await afterPendingUpdates()

        #expect(tables(in: window.contentView).first === table, "the list is the same one")
        try #require(table.selectedRow == firstRow, "the list selects the first row")
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
        let launchOffset = clipOffset(of: table)
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
            // B-105: its very top, above the first header's top margin.
            let launched = try #require(launchOffset)
            let landed = try #require(clipOffset(of: table))
            #expect(abs(landed - launched) <= 0.5, "the list is back where it launched")
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

    /// B-105 (P2): the last row closes while the Terminals section is
    /// scrolled off below (the user went up to the agents). Its going
    /// moves nothing on screen, so the list stays where the user put it:
    /// no landing on the top or on a selected agent that's off screen.
    /// Parked mid-list, so either jump shows, or with the section's header
    /// a row below the bottom edge, where the list may already keep its
    /// views: only what shows counts. (Any nearer, and the list's own
    /// clamp to its shorter content moves it a point or two.)
    @Test(arguments: ["no selection", "a selected agent off screen"], ["mid-list", "a row below the bottom edge"])
    func closingTheLastRowScrolledOffLeavesTheListWhereItIs(_ selection: String, _ parked: String) async throws {
        let terminals = LeoWindowTerminals()
        let (window, model) = try makeWindowAndModel(terminals: terminals)
        defer { window.close() }
        let table = try await settledTable(in: window)
        if selection == "a selected agent off screen" { model.userSelected(Self.agents(count: Self.agentCount)[0].id) }
        let shell = try await revealedLastRow(in: table, terminals: terminals)
        let header = table.numberOfRows - 2
        let parkedY = parked == "mid-list"
            ? table.rect(ofRow: Self.agentCount / 2).minY // an agent halfway down at the top edge
            : table.rect(ofRow: header).minY - table.visibleRect.height - table.rect(ofRow: header - 1).height
        table.scroll(NSPoint(x: table.visibleRect.minX, y: parkedY))
        await afterPendingUpdates()
        try #require(!isVisible(row: 0, in: table) && !table.visibleRect.intersects(table.rect(ofRow: header)),
                     "the list is parked between its top and the Terminals section")
        let offset = table.visibleRect.minY
        let rowsBefore = table.numberOfRows

        terminals.remove(shell)
        await afterPendingUpdates()

        try #require(table.numberOfRows < rowsBefore, "the Terminals section is gone")
        #expect(tables(in: window.contentView).first === table, "the list is the same one")
        #expect(table.visibleRect.minY == offset, "the list stays where it was")
    }

    /// D-188: the filter hiding the Terminals section isn't its closing,
    /// so the list doesn't land on its top, even with the section on
    /// screen and nothing selected. A filter every agent matches keeps
    /// the list long, so a landing would show. The shell retitles first
    /// (as a new one does once it starts), so the sidebar last saw its
    /// terminals change with the section on screen.
    @Test func filteringAwayTheTerminalsSectionDoesNotLandOnTheTop() async throws {
        let terminals = LeoWindowTerminals()
        let (window, model) = try makeWindowAndModel(terminals: terminals)
        defer { window.close() }
        let table = try await settledTable(in: window)
        let shell = try await revealedLastRow(in: table, terminals: terminals)
        terminals.retitle(shell, to: "zsh")
        await afterPendingUpdates()
        try #require(isVisible(row: table.numberOfRows - 1, in: table), "the row is still on screen")
        let rowsBefore = table.numberOfRows

        model.query = "agent"
        await afterPendingUpdates()

        try #require(tables(in: window.contentView).first === table, "the list is the same one")
        try #require(table.numberOfRows < rowsBefore && table.numberOfRows >= Self.agentCount, "the filter hides only the Terminals section")
        #expect(!isVisible(row: 0, in: table), "the list stays away from its top")
    }

    /// B-105: the section counts as on screen with only its "Terminals"
    /// header showing at the bottom edge and its row below it, so the last
    /// row's closing lands the list on its top -- where it launched.
    @Test func closingTheLastRowWithOnlyItsHeaderShowingLands() async throws {
        let terminals = LeoWindowTerminals()
        let (window, _) = try makeWindowAndModel(terminals: terminals)
        defer { window.close() }
        let table = try await settledTable(in: window)
        let launched = try #require(clipOffset(of: table))
        let shell = try await revealedLastRow(in: table, terminals: terminals)
        let header = table.numberOfRows - 2
        // Half the header above the bottom edge.
        table.scroll(NSPoint(x: table.visibleRect.minX, y: table.rect(ofRow: header).midY - table.visibleRect.height))
        await afterPendingUpdates()
        try #require(table.visibleRect.intersects(table.rect(ofRow: header)), "the header shows")
        try #require(!table.visibleRect.intersects(table.rect(ofRow: header + 1)), "the terminal row is below the edge")
        try #require(!isVisible(row: 0, in: table), "the list is away from its top")
        let rowsBefore = table.numberOfRows

        terminals.remove(shell)
        await afterPendingUpdates()

        try #require(table.numberOfRows < rowsBefore, "the Terminals section is gone")
        #expect(isVisible(row: 0, in: table), "the list is at its top")
        let landed = try #require(clipOffset(of: table))
        #expect(abs(landed - launched) <= 0.5, "the list is back where it launched")
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
    ///
    /// Its window is `turns` main-queue hops, no more. A "nothing moved"
    /// check after it sees only a scroll that lands inside that window --
    /// the reveal's own path, a hop after SwiftUI's update. A scroll that
    /// lands later (animated, or deferred by `asyncAfter`, a timer or
    /// `Task.sleep`) comes after the check and passes unseen.
    private func afterPendingUpdates(turns: Int = 5) async {
        for _ in 0 ..< turns { await nextTurn() }
    }

    /// Lets the main run loop turn until `condition` holds, at most
    /// `limit` times: for a change that has a sign of its own to wait for.
    /// Counts turns, not time.
    private func turns(limit: Int = 50, until condition: () -> Bool) async -> Bool {
        for _ in 0 ..< limit where !condition() { await nextTurn() }
        return condition()
    }

    private func nextTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    /// How far right `row`'s drawing reaches, in points: for a terminal
    /// row, the end of its title (a spacer follows it). Drawn from the
    /// list's own view for the row, made if it's off screen, so it shows
    /// what the list has rather than what the model holds. Pixels, as
    /// SwiftUI gives the test host no accessibility text for the row.
    /// `nil` when the row draws nothing.
    private func drawingEnd(ofRow row: Int, in table: NSTableView) -> CGFloat? {
        guard row >= 0, row < table.numberOfRows,
              let view = table.view(atColumn: 0, row: row, makeIfNecessary: true),
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        // The row's far right is the spacer's: background.
        let background = Self.rgba(rep.colorAt(x: rep.pixelsWide - 1, y: rep.pixelsHigh / 2))
        let lastDrawn = (0 ..< rep.pixelsWide).reversed().first { x in
            (0 ..< rep.pixelsHigh).contains { y in !Self.isNear(Self.rgba(rep.colorAt(x: x, y: y)), background) }
        }
        return lastDrawn.map { CGFloat($0 + 1) * view.bounds.width / CGFloat(rep.pixelsWide) }
    }

    private static func rgba(_ color: NSColor?) -> [CGFloat] {
        guard let color = color?.usingColorSpace(.deviceRGB) else { return [0, 0, 0, 0] }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    }

    /// Within anti-aliasing's faintest fringe of each other.
    private static func isNear(_ lhs: [CGFloat], _ rhs: [CGFloat]) -> Bool {
        zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.1 }
    }

    /// Where the list's scroll view shows its content from, insets and
    /// margins included: unlike `visibleRect`, not cut off at the table.
    private func clipOffset(of table: NSTableView) -> CGFloat? {
        table.enclosingScrollView?.contentView.bounds.minY
    }

    /// The whole row (to within a point) is within what the list's scroll
    /// view shows: a row cut off at an edge isn't revealed.
    private func isVisible(row: Int, in table: NSTableView) -> Bool {
        guard row >= 0, row < table.numberOfRows else { return false }
        let rect = table.rect(ofRow: row).insetBy(dx: 0, dy: 1)
        return table.visibleRect.contains(rect)
    }

    /// The window's list once it first fills: more than `rows` rows (by
    /// default, more than the agents alone). The suite's only wait on time
    /// (B-099): a new window's first population has no change of the
    /// test's own to count turns from. Every later change counts turns.
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
