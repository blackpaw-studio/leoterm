import AppKit
import GhosttyKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-333: splitting a terminal row works as splitting a Ghostty tab does.
/// ⌘D / ⇧⌘D -- any `new_split` -- split straight into a new shell, no
/// picker, starting from the config Ghostty's split hands it (the pane's
/// working directory). Ghostty's own split navigation, equalize and
/// resize act on the layout, ⌘W on a pane hands focus to its neighbour,
/// and the layout comes back as it was left after another row was shown.
/// Agents keep the picker (D-212).
@MainActor @Suite(.serialized) struct LeoRowSplitIntoShellTests {
    private typealias Fixture = LeoRowLayoutFixture

    /// ⌘D (`new_split:right`) and ⇧⌘D (`new_split:down`) on a shown row,
    /// through the core as the keys run them: a new shell beside it, which
    /// the host knows as a pane of the row's layout -- not a row of its own.
    @Test(arguments: [("new_split:right", true), ("new_split:down", false)])
    func commandDOnATerminalRowSplitsStraightIntoAShell(_ action: String, _ isSideBySide: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let row = try fixture.newRow()
        let rowView = try #require(fixture.view(row))

        #expect(fixture.perform(action, on: rowView))

        #expect(await fixture.turnsUntil { fixture.shown().count == 2 }, "it split")
        let new = try #require(fixture.shown().first { $0 !== rowView })
        let split = try #require(fixture.rootSplit)
        if case .horizontal = split.direction { #expect(isSideBySide) } else { #expect(!isSideBySide) }
        #expect(fixture.host.isOpen(fixture.handle(new)), "the host registered it")
        #expect(fixture.terminals.rows.map(\.id) == [row.surfaceID], "a pane of the row's layout, not a row")
        #expect(fixture.terminals.selection == row.surfaceID)
        #expect(!fixture.session.isPickerPresented, "no picker")
        #expect(fixture.host.splitsIntoShell(in: fixture.windowID), "the next split goes straight to a shell too")
    }

    /// The new shell starts from the config the split is handed, as
    /// upstream's split does: ⌘D's is the pane's own (its working
    /// directory). Here a scratch directory stands in for it.
    @Test func aSplitShellStartsFromTheConfigItIsGiven() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let row = try fixture.newRow()
        let rowView = try #require(fixture.view(row))
        let directory = FileManager.default.temporaryDirectory.appending(path: "leo-B333-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = directory.path
        config.command = "/bin/sh -c 'pwd -P > cwd.txt; exec /bin/cat'"

        let new = try #require(fixture.controller.newSplit(at: rowView, direction: .right, baseConfig: config))

        #expect(fixture.host.isOpen(fixture.handle(new)))
        let expected = try #require(realpath(directory.path, nil).map { path in
            defer { free(path) }
            return String(cString: path)
        })
        let written = directory.appending(path: "cwd.txt")
        #expect(await fixture.eventually(.seconds(8)) {
            (try? String(contentsOf: written, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == expected
        }, "it started in the directory it was given")
    }

    /// An agent's layout keeps the picker (D-212), and so does a shell
    /// split beside it: only a row's layout splits straight into a shell.
    @Test func commandDOnAnAgentStillOpensThePicker() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let agent = try fixture.attachAgent()

        #expect(!fixture.host.splitsIntoShell(in: fixture.windowID), "an agent: the picker")
        _ = try fixture.pickerSplit(beside: agent)
        #expect(!fixture.host.splitsIntoShell(in: fixture.windowID), "a shell beside an agent: the picker")
        _ = try fixture.newRow()
        #expect(fixture.host.splitsIntoShell(in: fixture.windowID), "a row: straight to a shell")
    }

    /// A row's layout -- split twice, one pane zoomed and focused -- comes
    /// back as it was left once another row was shown: the same surfaces
    /// in the same shape, zoom included, the row selected, and the pane
    /// that had focus focused again.
    @Test func aRowKeepsItsSplitLayoutAcrossASwitch() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let row = try fixture.newRow()
        let rowView = try #require(fixture.view(row))
        let right = try #require(fixture.split(rowView, .right))
        let below = try #require(fixture.split(right, .down))
        try #require(await fixture.focusLands(on: below))
        Ghostty.moveFocus(to: right)
        try #require(
            await fixture.eventually(.seconds(10)) {
                fixture.controller.window?.firstResponder === right && fixture.controller.focusedSurface === right
            },
            "SwiftUI names the middle pane focused"
        )
        fixture.perform("toggle_split_zoom", on: right)
        try #require(await fixture.eventually { fixture.controller.surfaceTree.zoomed != nil }, "zoomed")
        try #require(
            await fixture.eventually(.seconds(10)) {
                fixture.controller.window?.firstResponder === right && fixture.controller.focusedSurface === right
            },
            "the zoomed pane keeps focus"
        )
        let layout = fixture.controller.surfaceTree
        let other = try fixture.newRow()
        try #require(fixture.terminals.selection == other.surfaceID)

        #expect(fixture.host.reveal(row))

        #expect(fixture.controller.surfaceTree.root == layout.root, "the same surfaces in the same shape")
        #expect(fixture.controller.surfaceTree.zoomed == layout.zoomed, "zoom included")
        #expect(fixture.shown().map(ObjectIdentifier.init) == [rowView, right, below].map(ObjectIdentifier.init))
        #expect(fixture.terminals.rows.map(\.id) == [row.surfaceID, other.surfaceID])
        #expect(fixture.terminals.selection == row.surfaceID)
        #expect(fixture.controller.focusedSurface === right)
        #expect(await fixture.focusLands(on: right), "the pane focused at switch-away")
    }

    /// ⌘W on a pane split beside the row: focus moves where Ghostty moves
    /// it, and the row stays.
    @Test func closingASplitPaneFocusesItsNeighbour() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let row = try fixture.newRow()
        let rowView = try #require(fixture.view(row))
        let right = try #require(fixture.split(rowView, .right))
        let below = try #require(fixture.split(right, .down))
        try #require(await fixture.eventually(.seconds(10)) {
            fixture.controller.window?.firstResponder === below && fixture.controller.focusedSurface === below
        })
        let node = try #require(fixture.controller.surfaceTree.root?.node(view: below))
        let expected = try #require(fixture.controller.surfaceTree.leoFocusAfterClosing(node, focused: below))

        try fixture.closePane(below)

        #expect(await fixture.focusLands(on: expected), "Ghostty's pick")
        #expect(await fixture.turnsUntil { !fixture.host.isOpen(fixture.handle(below)) })
        #expect(fixture.terminals.rows.map(\.id) == [row.surfaceID])
        #expect(fixture.host.isOpen(row) && fixture.host.isOpen(fixture.handle(right)))
    }

    /// Ghostty's split navigation (⌘[ / ⌘], ⌥⌘arrows), equalize and resize
    /// keybinds act on a row's layout: Leo intercepts none of them.
    @Test func gotoEqualizeResizeActOnARowLayout() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let row = try fixture.newRow()
        let rowView = try #require(fixture.view(row))
        let right = try #require(fixture.split(rowView, .right))
        try #require(await fixture.focusLands(on: right))

        fixture.perform("goto_split:previous", on: right)
        #expect(await fixture.focusLands(on: rowView), "⌘[")
        fixture.perform("goto_split:right", on: rowView)
        #expect(await fixture.focusLands(on: right), "⌥⌘→")

        fixture.perform("resize_split:left,100", on: right)
        #expect(await fixture.eventually { (fixture.rootSplit?.ratio ?? 0.5) < 0.5 }, "the divider moved left")
        fixture.perform("equalize_splits", on: right)
        #expect(await fixture.eventually { fixture.rootSplit?.ratio == 0.5 }, "equalized")
    }

    /// ⌘Z of New Split takes the pane out (its handle closes); ⌘⇧Z puts
    /// the same shell back as a pane of the row's layout, handle and all
    /// (B-108).
    @Test func undoAndRedoOfASplitKeepItsShellRegistered() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let undoManager = try #require(fixture.controller.undoManager)
        undoManager.leoRemoveActionsTestsCanReplay(ghostty: fixture.controller.ghostty)
        let row = try fixture.newRow()
        let rowView = try #require(fixture.view(row))
        let new = try #require(undoManager.leoInOwnUndoGroup { fixture.split(rowView) })
        let pane = fixture.handle(new)
        try #require(fixture.host.isOpen(pane))

        undoManager.leoUndoLastGroup()

        #expect(fixture.shown().map(ObjectIdentifier.init) == [ObjectIdentifier(rowView)])
        #expect(await fixture.turnsUntil { !fixture.host.isOpen(pane) })

        undoManager.redo()

        #expect(fixture.shown().contains { $0 === new }, "upstream's redo")
        #expect(await fixture.turnsUntil { fixture.host.isOpen(pane) }, "its handle is back")
        #expect(fixture.terminals.rows.map(\.id) == [row.surfaceID], "a pane, not a row")
    }

    // MARK: The row's menu (B-177)

    /// Split Right / Split Down on the row's menu, once the row shows:
    /// the split ⌘D makes beside its shell, straight into a shell.
    @Test(arguments: [LeoSplitDirection.right, .down])
    func rowMenuSplitGoesStraightToAShell(_ direction: LeoSplitDirection) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let row = try fixture.newRow()
        let rowView = try #require(fixture.view(row))

        fixture.host.splitTerminal(row, direction: direction)

        #expect(fixture.shown().count == 2, "it split")
        let new = try #require(fixture.shown().first { $0 !== rowView })
        #expect(fixture.host.isOpen(fixture.handle(new)))
        #expect(fixture.terminals.rows.map(\.id) == [row.surfaceID])
        #expect(!fixture.session.isPickerPresented, "no picker")
    }
}
