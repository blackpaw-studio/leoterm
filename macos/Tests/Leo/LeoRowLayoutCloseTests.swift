import AppKit
import GhosttyKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-333: Close on a row's menu closes the row's whole layout, as closing
/// a Ghostty tab with splits does: one confirm names every busy pane in
/// it, shown or hidden. Cancel keeps all of it; Close lets all of it go,
/// and the neighbouring row (or the start screen) shows in its place. ⌘W
/// stays per pane (B-082).
@MainActor @Suite(.serialized) struct LeoRowLayoutCloseTests {
    private typealias Fixture = LeoRowLayoutFixture

    private final class Weak {
        weak var view: Ghostty.SurfaceView?
        init(_ view: Ghostty.SurfaceView?) { self.view = view }
    }

    private func title(_ view: Ghostty.SurfaceView, _ title: String, in fixture: Fixture) async -> Bool {
        view.setTitle(title)
        return await fixture.eventually { view.title == title }
    }

    /// A row titled "editor" with two panes split beside it, all shown:
    /// "editor" and "build" busy, the third a shell at its prompt. Returns
    /// their handles, and weak references to their surfaces.
    private func busyLayout(_ fixture: Fixture) async throws -> ([AttachmentHandle], [Weak]) {
        let row = try fixture.newRow(running: Fixture.standIn)
        let rowView = try #require(fixture.view(row))
        let busyView = try #require(fixture.split(rowView, .right, running: Fixture.standIn))
        let idleView = try #require(fixture.split(busyView, .down))
        let titled = await title(rowView, "editor", in: fixture)
        let titledToo = await title(busyView, "build", in: fixture)
        try #require(titled && titledToo)
        try #require(await fixture.eventually(.seconds(15)) {
            rowView.needsConfirmQuit && busyView.needsConfirmQuit && !idleView.needsConfirmQuit
        }, "two busy panes, and a shell at its prompt")
        return ([row, fixture.handle(busyView), fixture.handle(idleView)], [rowView, busyView, idleView].map { Weak($0) })
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["shown", "hidden"])
    func closingARowWithSplitsAsksOnceForEveryBusyPane(_ state: String) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let neighbour = try fixture.newRow()
        let neighbourView = try #require(fixture.view(neighbour))
        let (panes, views) = try await busyLayout(fixture)
        let row = panes[0]
        let shape = fixture.controller.surfaceTree.map(ObjectIdentifier.init)
        if state == "hidden" { try #require(fixture.host.reveal(neighbour)) }

        await fixture.host.closeTerminalFromMenu(row)

        let asked = Fixture.Controller.Asked(
            messageText: "Close “editor” and “build”?", informativeText: LeoCloseConfirmation.rowLayoutInformativeText
        )
        #expect(fixture.controller.asked == [asked], "one confirm, naming each busy pane")
        #expect(panes.allSatisfy(fixture.host.isOpen), "Cancel keeps all of it")
        #expect(fixture.terminals.rows.map(\.id) == [neighbour.surfaceID, row.surfaceID])
        if state == "shown" { #expect(fixture.shown().map(ObjectIdentifier.init) == shape) }

        fixture.controller.answer = .alertFirstButtonReturn
        await fixture.host.closeTerminalFromMenu(row)

        #expect(fixture.controller.asked == [asked, asked])
        #expect(await fixture.turnsUntil { !panes.contains(where: fixture.host.isOpen) }, "Close lets all of it go")
        #expect(fixture.terminals.rows.map(\.id) == [neighbour.surfaceID])
        #expect(fixture.shown().map(ObjectIdentifier.init) == [ObjectIdentifier(neighbourView)], "the neighbour shows")
        #expect(fixture.terminals.selection == neighbour.surfaceID)
        #expect(fixture.kept().isEmpty)
        #expect(!fixture.windowClosed)
        #expect(await fixture.eventually { views.allSatisfy { $0.view == nil } }, "every pane's shell ends")
    }

    /// The last row: Close leaves the start screen; the window stays.
    @Test(.timeLimit(.minutes(1)))
    func closingTheLastRowWithSplitsLeavesTheStartScreen() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let row = try fixture.newRow(running: Fixture.standIn)
        let rowView = try #require(fixture.view(row))
        let splitView = try #require(fixture.split(rowView, .right, running: Fixture.standIn))
        fixture.controller.answer = .alertFirstButtonReturn

        await fixture.host.closeTerminalFromMenu(row)

        #expect(await fixture.turnsUntil { !fixture.host.isOpen(fixture.handle(splitView)) })
        #expect(!fixture.host.isOpen(row))
        #expect(fixture.shown().isEmpty, "the start screen")
        #expect(fixture.terminals.rows.isEmpty)
        #expect(!fixture.windowClosed)
    }
}
