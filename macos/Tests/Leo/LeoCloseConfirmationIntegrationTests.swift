import AppKit
import GhosttyKit
import Testing

@testable import Ghostty

/// B-088 against a real `TerminalController`: every "Close …?" confirm a
/// window shows for a busy terminal names the pane or row it closes.
/// Needs the app's real `Ghostty.App`.
///
/// Windows are built but never shown or made key, and no alert is ever
/// put up: `ConfirmRecordingController` records what it would ask and
/// answers itself. Every terminal here runs `/bin/cat`, never a shell
/// (whose prompt would retitle it) and never a real agent.
@MainActor @Suite(.serialized) struct LeoCloseConfirmationIntegrationTests {
    private static let standIn = "/bin/cat"

    /// A window controller whose close confirms are recorded and answered
    /// with `answer` instead of shown.
    @MainActor private final class ConfirmRecordingController: TerminalController {
        struct Asked: Equatable {
            let messageText: String
            let informativeText: String
        }

        var asked: [Asked] = []
        var answer: NSApplication.ModalResponse = .alertSecondButtonReturn

        override func confirmCloseAsync(
            messageText: String,
            informativeText: String,
            confirmButtonTitle: String = "Close"
        ) async -> NSApplication.ModalResponse? {
            asked.append(Asked(messageText: messageText, informativeText: informativeText))
            return answer
        }
    }

    @MainActor private struct Fixture {
        let host: GhosttyAttachContentHost
        let configs: LeoRequestConfigStore
        let controller: ConfirmRecordingController
        let origin: LeoWindowID

        func shown() -> [Ghostty.SurfaceView] { Array(controller.surfaceTree) }
        func view(_ handle: AttachmentHandle) -> Ghostty.SurfaceView? { shown().first { $0.id == handle.surfaceID } }
    }

    private static var ghostty: Ghostty.App? { (NSApp.delegate as? AppDelegate)?.ghostty }

    private func makeFixture() throws -> Fixture {
        let ghostty = try #require(Self.ghostty, "these tests need the app's Ghostty.App")
        let app = try #require(ghostty.app)
        let first = Ghostty.SurfaceView(app, baseConfig: Self.standInConfig())
        let controller = ConfirmRecordingController(ghostty, withSurfaceTree: SplitTree(view: first))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let registry = LeoWindowSessionRegistry()
        let origin = registry.makeSession(window: controller.window, controller: controller, defaults: LeoInMemoryDefaults()).id
        let session = try #require(controller.leoSession)
        let configs = LeoRequestConfigStore()
        let host = GhosttyAttachContentHost(registry: registry, requestConfigStore: configs) { .init(isActive: false, keyWindow: nil) }
        // What `LeoRuntime` wires for the app's own sessions.
        let sessionID = session.id
        session.terminals.closeRequested = { [weak host] in host?.closeTerminal(AttachmentHandle(surfaceID: $0, windowID: sessionID)) }
        session.terminals.hasBusyHiddenShell = { [weak host] in host?.hiddenTerminalsNeedConfirmQuit(in: sessionID) ?? false }
        return Fixture(host: host, configs: configs, controller: controller, origin: origin)
    }

    private func close(_ fixture: Fixture) {
        fixture.controller.closeTabImmediately(registerRedo: false)
    }

    private static func standInConfig() -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        config.command = standIn
        return config
    }

    /// A terminal row, as ⌘T makes one, busy with the stand-in.
    private func newRow(_ fixture: Fixture) throws -> AttachmentHandle {
        let requestID = UUID()
        fixture.configs.set(Self.standInConfig(), for: requestID)
        return try fixture.host.showInContent(command: "", workingDirectory: nil, origin: fixture.origin, requestID: requestID)
    }

    /// A plain shell split beside `row`, busy with the stand-in.
    private func newSplit(_ fixture: Fixture, beside row: AttachmentHandle) throws -> AttachmentHandle {
        let requestID = UUID()
        fixture.configs.set(Self.standInConfig(), for: requestID)
        return try fixture.host.openSplit(
            command: "", workingDirectory: nil, origin: fixture.origin,
            sourceSurface: row.surfaceID, direction: .right, requestID: requestID
        )
    }

    private func title(_ view: Ghostty.SurfaceView, _ title: String) async -> Bool {
        view.setTitle(title)
        return await eventually { view.title == title }
    }

    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: ⌘W on a split's pane

    @Test func closingABusySplitPaneNamesThatPane() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let row = try newRow(fixture)
        let split = try newSplit(fixture, beside: row)
        let rowView = try #require(fixture.view(row))
        let splitView = try #require(fixture.view(split))
        #expect(await title(rowView, "editor"))
        #expect(await title(splitView, "build"))

        fixture.controller.closeSurface(try #require(fixture.controller.surfaceTree.root?.node(view: splitView)), withConfirmation: true)

        #expect(await eventually { !fixture.controller.asked.isEmpty })
        #expect(fixture.controller.asked.map(\.messageText) == ["Close “build”?"])
        #expect(fixture.controller.asked.first?.informativeText == LeoCloseConfirmation.paneInformativeText)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fixture.shown().map(\.id) == [row.surfaceID, split.surfaceID], "Cancel keeps both panes")
    }

    @Test func closingOneOfTwoEquallyNamedHorizontalPanesSaysWhichSide() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let row = try newRow(fixture)
        let split = try newSplit(fixture, beside: row)
        let rowView = try #require(fixture.view(row))
        let splitView = try #require(fixture.view(split))
        #expect(await title(rowView, "build"))
        #expect(await title(splitView, "build"))

        fixture.controller.closeSurface(try #require(fixture.controller.surfaceTree.root?.node(view: splitView)), withConfirmation: true)

        #expect(await eventually { !fixture.controller.asked.isEmpty })
        #expect(fixture.controller.asked.map(\.messageText) == ["Close “build (Right pane)”?"])
    }

    @Test func closingTheLeftOfTwoEquallyNamedHorizontalPanesSaysWhichSide() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let row = try newRow(fixture)
        let split = try newSplit(fixture, beside: row)
        let rowView = try #require(fixture.view(row))
        let splitView = try #require(fixture.view(split))
        #expect(await title(rowView, "build"))
        #expect(await title(splitView, "build"))

        fixture.controller.closeSurface(try #require(fixture.controller.surfaceTree.root?.node(view: rowView)), withConfirmation: true)

        #expect(await eventually { !fixture.controller.asked.isEmpty })
        #expect(fixture.controller.asked.map(\.messageText) == ["Close “build (Left pane)”?"])
    }

    @Test func confirmingASplitPaneClosesOnlyThatPane() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let row = try newRow(fixture)
        let split = try newSplit(fixture, beside: row)
        let splitView = try #require(fixture.view(split))
        fixture.controller.answer = .alertFirstButtonReturn

        fixture.controller.closeSurface(try #require(fixture.controller.surfaceTree.root?.node(view: splitView)), withConfirmation: true)

        #expect(await eventually { fixture.shown().map(\.id) == [row.surfaceID] })
    }

    @Test func closingAnAlreadyRemovedPaneDoesNotAskAgain() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let row = try newRow(fixture)
        let split = try newSplit(fixture, beside: row)
        let splitView = try #require(fixture.view(split))
        let staleNode = try #require(fixture.controller.surfaceTree.root?.node(view: splitView))

        fixture.controller.closeSurface(staleNode, withConfirmation: false)
        #expect(await eventually { fixture.shown().map(\.id) == [row.surfaceID] })

        fixture.controller.closeSurface(staleNode, withConfirmation: true)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fixture.controller.asked.isEmpty)
    }

    // MARK: ⌘W on a row with no split

    @Test func closingABusyRowNamesTheRow() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let row = try newRow(fixture)
        let rowView = try #require(fixture.view(row))
        #expect(await title(rowView, "deploy"))
        #expect(await eventually { fixture.controller.leoSession?.terminals.rows.first?.displayTitle == "deploy" })

        fixture.controller.closeSurface(try #require(fixture.controller.surfaceTree.root), withConfirmation: true)

        #expect(await eventually { !fixture.controller.asked.isEmpty })
        #expect(fixture.controller.asked.map(\.messageText) == ["Close “deploy”?"])
        #expect(fixture.controller.leoSession?.terminals.contains(row.surfaceID) == true, "Cancel keeps the row")
    }

    // MARK: Switching away from a busy split

    /// A row with a shell split beside it closes whole on a switch away
    /// (`LeoContentReplacement.fate`): the confirm names each busy shell.
    @Test func switchingAwayFromABusySplitNamesTheShellsThatClose() async throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let row = try newRow(fixture)
        let split = try newSplit(fixture, beside: row)
        let rowView = try #require(fixture.view(row))
        let splitView = try #require(fixture.view(split))
        #expect(await title(rowView, "editor"))
        #expect(await title(splitView, "build"))
        #expect(await eventually { rowView.needsConfirmQuit && splitView.needsConfirmQuit }, "the stand-in keeps both busy")

        #expect(await !fixture.host.confirmReplacingContent(origin: fixture.origin), "Cancel keeps the content")

        #expect(fixture.controller.asked.map(\.messageText) == ["Close “editor” and “build”?"])
    }
}
