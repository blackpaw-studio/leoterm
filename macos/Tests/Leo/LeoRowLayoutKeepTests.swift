import AppKit
import GhosttyKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-333: a terminal row owns its split layout, as a Ghostty tab does.
/// Switching away hides the whole layout -- its own shell and every shell
/// split beside it -- and nothing in it ends but by its own exit or the
/// row's close. A pane whose process ends while hidden leaves the layout;
/// the row's own pane leaving hands the row to a pane that stays (B-082).
@MainActor @Suite(.serialized) struct LeoRowLayoutKeepTests {
    private typealias Fixture = LeoRowLayoutFixture

    /// Switching away from a row with shells split beside it -- one busy
    /// -- never asks, and hides all of it: the same instances come back,
    /// in the same shape, when the row shows again.
    @Test func switchingAwayKeepsTheRowsLayoutWhole() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let row = try fixture.newRow()
        let busy = try fixture.pickerSplit(beside: row, running: Fixture.standIn)
        let idle = try fixture.pickerSplit(beside: busy)
        let busyView = try #require(fixture.view(busy))
        try #require(await fixture.eventually { busyView.needsConfirmQuit }, "the split's process is running")
        let layout = fixture.controller.surfaceTree
        let panes = fixture.shown()

        #expect(await fixture.host.confirmReplacingContent(origin: fixture.origin), "nothing closes, so nothing asks")
        _ = try fixture.attachAgent()

        #expect(fixture.controller.asked.isEmpty)
        #expect(Set(fixture.kept().map(ObjectIdentifier.init)) == Set(panes.map(ObjectIdentifier.init)), "the whole layout is kept")
        #expect([row, busy, idle].allSatisfy(fixture.host.isOpen))
        #expect(fixture.terminals.rows.map(\.id) == [row.surfaceID])

        #expect(fixture.host.reveal(row))

        #expect(fixture.controller.surfaceTree.root == layout.root, "the same surfaces in the same shape")
        #expect(fixture.shown().map(ObjectIdentifier.init) == panes.map(ObjectIdentifier.init))
        #expect(fixture.terminals.selection == row.surfaceID)
        #expect(!fixture.events.contains(.closed(busy)) && !fixture.events.contains(.closed(idle)))
    }

    /// A shell split beside a hidden row ends: only its pane leaves the
    /// layout. The row and its own shell stay kept.
    @Test func aHiddenRowsSplitPaneThatExitsLeavesTheRestKept() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let row = try fixture.newRow()
        let rowView = try #require(fixture.view(row))
        let ending = try fixture.pickerSplit(beside: row, running: "/bin/sleep 0.5")
        _ = try fixture.attachAgent()

        #expect(await fixture.eventually(.seconds(8)) { !fixture.host.isOpen(ending) }, "its pane leaves")
        #expect(fixture.kept().map(ObjectIdentifier.init) == [ObjectIdentifier(rowView)], "the row's shell stays kept")
        #expect(fixture.host.isOpen(row))
        #expect(fixture.terminals.rows.map(\.id) == [row.surfaceID])
        #expect(await fixture.turnsUntil { fixture.events.contains(.closed(ending)) })
        #expect(!fixture.events.contains(.closed(row)))

        #expect(fixture.host.reveal(row))
        #expect(fixture.shown().map(ObjectIdentifier.init) == [ObjectIdentifier(rowView)])
    }

    /// The row's own shell ends while hidden -- heard as its exit (Ghostty
    /// waiting for a key) or as Ghostty's close request: the row carries
    /// on in the shell split beside it, in its sidebar slot. Nothing busy
    /// is let go, and showing the row shows that shell.
    @Test(arguments: ["its exit", "its close request"])
    func aHiddenRowsOwnPaneExitingHandsTheRowToItsSplit(_ via: String) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let older = try fixture.newRow()
        let row = via == "its exit" ? try fixture.newRow(running: "/bin/sleep 0.5", waiting: true) : try fixture.newRow()
        let rowView = try #require(fixture.view(row))
        let split = try fixture.pickerSplit(beside: row, running: Fixture.standIn)
        let splitView = try #require(fixture.view(split))
        try #require(fixture.host.reveal(older))
        if via == "its close request" { fixture.postCloseRequest(rowView) }

        #expect(
            await fixture.eventually(.seconds(8)) { fixture.terminals.rows.map(\.id) == [older.surfaceID, split.surfaceID] },
            "the split carries the row on, in its slot"
        )
        #expect(!fixture.host.isOpen(row))
        #expect(fixture.host.isOpen(split))
        #expect(!splitView.processExited, "nothing busy is let go")
        #expect(fixture.kept().map(ObjectIdentifier.init) == [ObjectIdentifier(splitView)])
        #expect(await fixture.turnsUntil { fixture.events.contains(.closed(row)) })
        #expect(!fixture.events.contains(.closed(split)))

        #expect(fixture.host.reveal(split))
        #expect(fixture.shown().map(ObjectIdentifier.init) == [ObjectIdentifier(splitView)])
        #expect(fixture.terminals.selection == split.surfaceID)
    }

    /// A busy shell split beside a hidden row counts when the window
    /// closes (and so for ⌘Q and closing tabs): it asks first.
    @Test func windowCloseAsksForABusyHiddenSplitPane() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let row = try fixture.newRow()
        let rowView = try #require(fixture.view(row))
        try #require(await fixture.eventually(.seconds(15)) { !rowView.needsConfirmQuit }, "the row's shell reached its prompt")
        let busy = try fixture.pickerSplit(beside: row, running: Fixture.standIn)
        let busyView = try #require(fixture.view(busy))
        try #require(await fixture.eventually { busyView.needsConfirmQuit }, "the split's process is running")
        _ = try fixture.newRow()

        #expect(fixture.terminals.hasBusyHiddenShell(), "the hidden split's process")
        #expect(fixture.controller.leoNeedsConfirmClose)
    }
}
