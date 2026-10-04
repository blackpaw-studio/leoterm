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

    /// Fix round 2: a neighbour with nothing to show is passed over -- the
    /// rows after first, then those before, each nearest first.
    @Test func neighboursAreTheRowsAfterThenBeforeNearestFirst() {
        let d = UUID()

        #expect(list(a, b, c, d).neighbours(of: c) == [d, b, a])
        #expect(list(a, b, c, d).neighbours(of: a) == [b, c, d])
        #expect(list(a, b).neighbours(of: c).isEmpty, "not listed")
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

    /// B-079: the row shows the title it groups by, so " ~ " reads "~".
    @Test func aRowsTitleDropsSurroundingSpace() {
        #expect(list(a).retitling(a, to: "  ~ \n").rows.first?.displayTitle == "~")
        #expect(list(a).retitling(a, to: " vim  notes ").rows.first?.displayTitle == "vim  notes", "inner space stays")
    }

    /// Ghostty's own stand-in for a terminal that set no title isn't one.
    @Test func ghosttysPlaceholderTitleReadsTerminal() {
        #expect(list(a).retitling(a, to: "👻").rows.first?.displayTitle == "Terminal")
    }

    // MARK: A row carried on by another shell (B-082)

    @Test func replacingARowKeepsItsSlot() {
        let x = UUID()

        let replaced = list(a, b, c).replacing(b, with: LeoTerminalRow(id: x, title: "zsh"))

        #expect(replaced.rows.map(\.id) == [a, x, c])
        #expect(replaced.rows[1].title == "zsh", "titled by its own terminal")
    }

    @Test func replacingARowThatIsntListedChangesNothing() {
        #expect(list(a, b).replacing(c, with: LeoTerminalRow(id: UUID(), title: "")) == list(a, b))
    }

    @Test func replacingWithARowAlreadyListedKeepsOne() {
        #expect(list(a, b, c).replacing(b, with: LeoTerminalRow(id: c, title: "")).rows.map(\.id) == [a, c])
        #expect(list(a, b).replacing(b, with: LeoTerminalRow(id: b, title: "zsh")).rows.map(\.title) == ["", "zsh"], "itself: retitled")
    }

    @Test func replacingCarriesTheSelection() {
        let x = UUID()
        let terminals = LeoWindowTerminals()
        terminals.add(a, title: "")
        terminals.add(b, title: "")
        terminals.select(b)

        terminals.replace(b, with: x, title: "zsh")

        #expect(terminals.rows.map(\.id) == [a, x])
        #expect(terminals.rows.map(\.title) == ["", "zsh"])
        #expect(terminals.selection == x)
    }

    @Test func replacingLeavesASelectionElsewhere() {
        let x = UUID()
        let terminals = LeoWindowTerminals()
        terminals.add(a, title: "")
        terminals.add(b, title: "")
        terminals.select(a)

        terminals.replace(b, with: x, title: "")
        terminals.replace(c, with: UUID(), title: "")

        #expect(terminals.rows.map(\.id) == [a, x], "a row that isn't listed changes nothing")
        #expect(terminals.selection == a)
    }

    // MARK: The row's menu (B-177)

    /// Each menu action reaches only a row this window lists, and moves no
    /// selection by itself.
    @Test func menuActionsReachOnlyListedRows() {
        let terminals = LeoWindowTerminals()
        terminals.add(a, title: "")
        terminals.add(b, title: "")
        terminals.select(b)
        var renamed: [(UUID, String)] = []
        var split: [(UUID, LeoSplitDirection)] = []
        var closed: [UUID] = []
        terminals.renameRequested = { renamed.append(($0, $1)) }
        terminals.splitRequested = { split.append(($0, $1)) }
        terminals.closeFromMenuRequested = { closed.append($0) }

        terminals.rename(a, to: "build")
        terminals.split(a, .right)
        terminals.split(a, .down)
        terminals.closeFromMenu(a)
        terminals.rename(c, to: "nope")
        terminals.split(c, .right)
        terminals.closeFromMenu(c)

        #expect(renamed.map(\.0) == [a] && renamed.map(\.1) == ["build"])
        #expect(split.map(\.0) == [a, a] && split.map(\.1) == [.right, .down])
        #expect(closed == [a])
        #expect(terminals.selection == b, "the menu acts on its row, not the selection")
    }

    /// Rename with the prefilled title left as it was changes nothing (no
    /// title is pinned); anything else, blank included, is handed on.
    @Test func theRenameSheetHandsOnOnlyAChangedName() {
        #expect(LeoTerminalRenameSheet.submission(name: "~/src", currentTitle: "~/src") == nil)
        #expect(LeoTerminalRenameSheet.submission(name: "build", currentTitle: "~/src") == "build")
        #expect(LeoTerminalRenameSheet.submission(name: "", currentTitle: "~/src") == "", "blank restores the live title")
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

    // MARK: Who upstream focuses after a pane closes (B-107)

    /// Three panes split left to right, in tree order.
    private func threePanes() throws -> (SplitTree<MockView>, [MockView]) {
        let views = [MockView(), MockView(), MockView()]
        let tree = try SplitTree(view: views[0])
            .inserting(view: views[1], at: views[0], direction: .right)
            .inserting(view: views[2], at: views[1], direction: .right)
        return (tree, views)
    }

    /// Upstream's `findNextFocusTargetAfterClosing`: the focused pane
    /// closing hands focus to the next pane when it was the leftmost, else
    /// to the previous one ([row,a,b] -> a, [a,row,b] -> a, [a,b,row] -> b).
    @Test(arguments: [(0, 1), (1, 0), (2, 1)])
    func leoFocusAfterClosingMirrorsUpstream(_ closing: Int, _ expected: Int) throws {
        let (tree, views) = try threePanes()
        let node = try #require(tree.root?.node(view: views[closing]))

        #expect(tree.leoFocusAfterClosing(node, focused: views[closing]) === views[expected])
    }

    /// Closing a pane that doesn't hold focus leaves focus where it is;
    /// with nothing focused there is nothing to follow.
    @Test(arguments: [0, 1, 2])
    func leoFocusAfterClosingAnUnfocusedPaneKeepsTheFocus(_ closing: Int) throws {
        let (tree, views) = try threePanes()
        let node = try #require(tree.root?.node(view: views[closing]))
        let focused = views[(closing + 1) % views.count]

        #expect(tree.leoFocusAfterClosing(node, focused: focused) === focused)
        #expect(tree.leoFocusAfterClosing(node, focused: nil) == nil)
    }
}
