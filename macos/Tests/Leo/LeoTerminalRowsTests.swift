import Foundation
import Testing

@testable import Ghostty

/// B-057: a window's Terminals rows -- the list, its neighbour pick on
/// close, and how its selection composes with the app-wide agent list.
@MainActor struct LeoTerminalRowsTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let window = LeoWindowID()
    private let worker = LeoAgentRow(host: .local, name: "worker", template: nil, status: .running, activity: .idle, actionDetail: nil)

    private func list(_ ids: UUID...) -> LeoTerminalList {
        ids.reduce(LeoTerminalList()) { $0.adding(LeoTerminalRow(id: $1, title: "")) }
    }

    // MARK: The list

    @Test func rowsListInTheOrderTheyWereMade() {
        #expect(list(a, b, c).rows.map(\.id) == [a, b, c])
    }

    @Test func addingARowTwiceKeepsOne() {
        #expect(list(a, a).rows.map(\.id) == [a])
    }

    @Test(arguments: [
        ("middle", 1, 2),
        ("last", 2, 1),
        ("first", 0, 1),
    ])
    func closingARowPicksTheNextElseThePrevious(_ which: String, _ closing: Int, _ expected: Int) {
        let ids = [a, b, c]

        #expect(list(a, b, c).neighbour(of: ids[closing]) == ids[expected], "\(which)")
    }

    @Test func theOnlyRowHasNoNeighbour() {
        #expect(list(a).neighbour(of: a) == nil)
        #expect(list(a).neighbour(of: b) == nil, "not listed")
    }

    @Test func aRowIsTitledByItsTerminalElseTerminal() {
        let titled = list(a).retitling(a, to: "vim notes.txt")

        #expect(titled.rows.first?.displayTitle == "vim notes.txt")
        #expect(list(a).rows.first?.displayTitle == "Terminal")
        #expect(list(a).retitling(a, to: "  ").rows.first?.displayTitle == "Terminal")
    }

    /// Ghostty's own stand-in for a terminal that set no title isn't one.
    @Test func ghosttysPlaceholderTitleReadsTerminal() {
        #expect(list(a).retitling(a, to: "👻").rows.first?.displayTitle == "Terminal")
    }

    // MARK: One window's rows

    @Test func removingTheSelectedRowClearsTheSelection() {
        let terminals = LeoWindowTerminals()
        terminals.add(a, title: "")
        terminals.add(b, title: "")
        terminals.select(a)

        terminals.remove(a)

        #expect(terminals.rows.map(\.id) == [b])
        #expect(terminals.selection == nil)
    }

    @Test func onlyAListedRowCanBeSelected() {
        let terminals = LeoWindowTerminals()
        terminals.add(a, title: "")

        terminals.select(b)
        #expect(terminals.selection == nil)
        terminals.select(a)
        #expect(terminals.selection == a)
    }

    @Test func retitlingFollowsTheTerminal() {
        let terminals = LeoWindowTerminals()
        terminals.add(a, title: "zsh")

        terminals.retitle(a, to: "~/src")

        #expect(terminals.rows.map(\.title) == ["~/src"])
    }

    @Test func activatingSelectsAndShows() {
        let terminals = LeoWindowTerminals()
        var shown: [UUID] = []
        terminals.showRequested = { shown.append($0) }
        terminals.add(a, title: "")

        terminals.activate(a)
        terminals.activate(b)

        #expect(terminals.selection == a)
        #expect(shown == [a], "an unknown row shows nothing")
    }

    // MARK: Composing with the app-wide agent selection

    @Test func aSelectedTerminalWinsInItsWindow() {
        let model = LeoSidebarModel()
        let terminals = LeoWindowTerminals()
        terminals.add(a, title: "")
        model.selection = worker.id

        #expect(LeoSidebarSelection.current(model: model, terminals: terminals) == .agent(worker.id))
        terminals.select(a)
        #expect(LeoSidebarSelection.current(model: model, terminals: terminals) == .terminal(a))
        #expect(model.selection == worker.id, "the shared agent selection is untouched")
    }

    @Test func selectingAnAgentClearsTheWindowsTerminal() {
        let model = LeoSidebarModel()
        let terminals = LeoWindowTerminals()
        terminals.add(a, title: "")
        terminals.select(a)

        LeoSidebarSelection.select(.agent(worker.id), model: model, terminals: terminals)

        #expect(terminals.selection == nil)
        #expect(model.selection == worker.id)
        #expect(LeoSidebarSelection.current(model: model, terminals: terminals) == .agent(worker.id))
    }

    @Test func arrowingOntoATerminalSelectsWithoutShowing() {
        let model = LeoSidebarModel()
        let terminals = LeoWindowTerminals()
        var shown: [UUID] = []
        terminals.showRequested = { shown.append($0) }
        terminals.add(a, title: "")

        LeoSidebarSelection.select(.terminal(a), model: model, terminals: terminals)

        #expect(terminals.selection == a)
        #expect(shown.isEmpty)
    }

    @Test func returnOnASelectedTerminalShowsIt() {
        let model = LeoSidebarModel(snapshot: .init(rows: [worker], connectivity: .connected, generation: 1))
        let terminals = LeoWindowTerminals()
        var shown: [UUID] = []
        var attached: [LeoAgentRow.ID] = []
        terminals.showRequested = { shown.append($0) }
        model.attachRequested = { row, _, _ in attached.append(row.id) }
        model.selection = worker.id
        terminals.add(a, title: "")
        terminals.select(a)

        #expect(LeoSidebarSelection.canActivate(model: model, terminals: terminals))
        LeoSidebarSelection.activate(model: model, terminals: terminals, from: window)

        #expect(shown == [a])
        #expect(attached.isEmpty, "the terminal, not the app-wide agent selection")
    }

    @Test func returnWithNoTerminalSelectedIsTheAgents() {
        let model = LeoSidebarModel(snapshot: .init(rows: [worker], connectivity: .connected, generation: 1))
        let terminals = LeoWindowTerminals()
        var attached: [LeoAgentRow.ID] = []
        model.attachRequested = { row, _, _ in attached.append(row.id) }
        model.selection = worker.id

        LeoSidebarSelection.activate(model: model, terminals: terminals, from: window)

        #expect(attached == [worker.id])
    }

    @Test func returnHasNothingToDoWithNothingSelected() {
        #expect(!LeoSidebarSelection.canActivate(model: LeoSidebarModel(), terminals: LeoWindowTerminals()))
    }

    // MARK: What leaving the content area does (D-111)

    @Test(arguments: [
        ([LeoContentReplacement.Shown(isAgent: false, isTerminalRow: true, needsConfirmQuit: true)], LeoContentReplacement.Fate.keep),
        // A shell split beside a row has no row of its own: the whole
        // content closes (asking first when busy), as beside an agent.
        ([.init(isAgent: false, isTerminalRow: true, needsConfirmQuit: false), .init(isAgent: false, needsConfirmQuit: true)], .close),
        ([.init(isAgent: true, needsConfirmQuit: true)], .pool),
        ([.init(isAgent: true, needsConfirmQuit: true), .init(isAgent: false, isTerminalRow: true, needsConfirmQuit: false)], .close),
        ([.init(isAgent: false, needsConfirmQuit: false)], .close),
        ([], .close),
    ])
    func contentGoesWhereItsRowsLive(_ shown: [LeoContentReplacement.Shown], _ fate: LeoContentReplacement.Fate) {
        #expect(LeoContentReplacement.fate(shown) == fate)
    }

    /// D-111 retires D-106's ask for a terminal row: switching away hides
    /// it, so its busy process lives on.
    @Test func switchingAwayFromABusyTerminalRowNeverAsks() {
        let shown = [LeoContentReplacement.Shown(isAgent: false, isTerminalRow: true, needsConfirmQuit: true)]

        #expect(!LeoContentReplacement.needsConfirmation(shown))
    }

    /// Fix round 2: a busy shell split beside a row would close with it,
    /// so switching away asks first.
    @Test func aBusyShellSplitBesideATerminalRowAsks() {
        let shown = [
            LeoContentReplacement.Shown(isAgent: false, isTerminalRow: true, needsConfirmQuit: false),
            .init(isAgent: false, needsConfirmQuit: true),
        ]

        #expect(LeoContentReplacement.needsConfirmation(shown))
    }

    /// B-058 territory keeps today's safe behaviour: a shell beside an
    /// agent still closes with the switch, so it still asks when busy.
    @Test func aBusyTerminalRowBesideAnAgentStillAsks() {
        let shown = [
            LeoContentReplacement.Shown(isAgent: true, needsConfirmQuit: true),
            .init(isAgent: false, isTerminalRow: true, needsConfirmQuit: true),
        ]

        #expect(LeoContentReplacement.needsConfirmation(shown))
    }
}
