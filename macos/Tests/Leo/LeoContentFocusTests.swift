import AppKit
import Testing

@testable import Ghostty

/// B-087: once a row switch or the agent palette is done, the terminal
/// the window shows is its first responder, and its cursor is drawn
/// focused (`focused`, which libghostty draws as a filled cursor; a hollow
/// one is `false`).
///
/// Each test drives a real start-screen `TerminalController` made key, as
/// the app's window is, and the real `LeoAgentPalettePanel`. A test
/// suite elsewhere may take key status meanwhile (suites share one app),
/// so the cursor is checked against the window's key state rather than
/// assuming it: a key window's first responder draws focused, and nothing
/// else in it does.
///
/// Needs the test host's `Ghostty.App`; without it the test fails rather
/// than passing silently.
@MainActor @Suite(.serialized)
struct LeoContentFocusTests {
    /// Covers the host step only: `showInContent` / `reveal` called
    /// directly, with a view in the window standing in for the sidebar
    /// list holding keyboard focus. The click → selection → route path
    /// that reaches the host is not driven here.
    @Test func aRowSwitchFocusesTheShownTerminal() async throws {
        let fixture = try await FocusFixture.make()
        defer { fixture.close() }
        let first = try fixture.fill()
        try await fixture.expectSettled(on: first.surface)

        fixture.focusSidebar()
        let second = try fixture.show()
        try await fixture.expectSettled(on: second.surface, "a new row shown in place of the first")

        fixture.focusSidebar()
        #expect(fixture.host.reveal(first.handle), "the first row was kept hidden")
        try await fixture.expectSettled(on: first.surface, "the hidden row shown again")
    }

    /// Escape closes the palette: the panel's Escape key reaches
    /// `LeoPickerPresentation.commit(.cancel)`, which dismisses it; the
    /// window becomes key again.
    @Test func dismissingThePaletteGivesFocusBackToTheTerminal() async throws {
        let fixture = try await FocusFixture.make()
        defer { fixture.close() }
        let shown = try fixture.fill().surface
        try await fixture.expectSettled(on: shown)

        let palette = try await fixture.presentPaletteForRequest()
        try palette.pressEscape()

        try await fixture.requireKeyAgain("after Escape")
        try await fixture.expectSettled(on: shown, "after the palette closed")
    }

    /// ⌘D's palette: a choice fills a new split while the palette is still
    /// the key window, and the palette closes a turn later (`requestEnded`).
    /// The new split keeps the focus it was given: the window becoming key
    /// again must not hand it back to the pane the split was made from.
    @Test func aSplitChosenInThePaletteKeepsFocusOnceThePaletteCloses() async throws {
        let fixture = try await FocusFixture.make()
        defer { fixture.close() }
        let source = try fixture.fill().surface
        try await fixture.expectSettled(on: source)

        let panel = try await fixture.presentPalette()
        let split = try fixture.split(from: source)
        DispatchQueue.main.async { panel.dismiss() }

        try await fixture.requireKeyAgain("after the palette closed")
        try await fixture.expectSettled(on: split, "the new split, not the pane it was split from")
    }
}

/// A key start-screen window with an attach host of its own; the
/// surfaces are plain shells (`command: ""`), never an agent.
@MainActor
private struct FocusFixture {
    let controller: TerminalController
    let window: NSWindow
    let host: GhosttyAttachContentHost
    let origin: LeoWindowID
    let sidebar: NSView

    /// Past the longest `Ghostty.moveFocus` retry chain (50 + 100 + 200 +
    /// 400 ms): a focus move still pending by then never lands.
    private static let pendingFocusMovesLand: Duration = .seconds(1)
    private static let timeout: Duration = .seconds(5)

    static func make() async throws -> FocusFixture {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty, "the test host has no Ghostty.App")
        try #require(ghostty.readiness == .ready, "the test host's Ghostty.App isn't ready")
        let controller = TerminalController(ghostty, withSurfaceTree: .init(), leoIsPlaceholder: true)
        guard let window = controller.window else {
            controller.closeTabImmediately(registerRedo: false)
            throw FixtureError.noWindow
        }
        let registry = LeoWindowSessionRegistry()
        let session = registry.makeSession(window: window, controller: controller, defaults: LeoInMemoryDefaults())
        let host = GhosttyAttachContentHost(registry: registry, requestConfigStore: LeoRequestConfigStore())
        let sidebar = SidebarStandIn()
        window.contentView?.addSubview(sidebar)
        window.makeKeyAndOrderFront(nil)
        return FocusFixture(controller: controller, window: window, host: host, origin: session.id, sidebar: sidebar)
    }

    func close() {
        controller.closeTabImmediately(registerRedo: false)
    }

    /// A row the window shows: its handle, and the surface showing it.
    struct Row {
        let handle: AttachmentHandle
        let surface: Ghostty.SurfaceView
    }

    func fill() throws -> Row {
        try row(host.fillPlaceholder(command: "", workingDirectory: nil, origin: origin, surfaceID: nil, requestID: UUID()))
    }

    func show() throws -> Row {
        try row(host.showInContent(command: "", workingDirectory: nil, origin: origin, requestID: UUID()))
    }

    func split(from source: Ghostty.SurfaceView) throws -> Ghostty.SurfaceView {
        let handle = try host.openSplit(
            command: "", workingDirectory: nil, origin: origin, sourceSurface: source.id, direction: .right, requestID: UUID()
        )
        return try row(handle).surface
    }

    func focusSidebar() {
        window.makeFirstResponder(sidebar)
    }

    /// The real palette over this window, once it has taken key status.
    func presentPalette() async throws -> LeoAgentPalettePanel {
        let panel = LeoAgentPalettePanel()
        panel.present(parent: window, model: LeoAgentPaletteModel(), onCommit: { _ in }, onRetry: {}, onResignKey: {})
        try #require(await eventually { panel.isKeyWindow }, "the palette never became key")
        return panel
    }

    /// The palette as ⌘O shows it: a real `LeoPickerPresentation` over
    /// this window driving the real panel, for a request it has begun.
    func presentPaletteForRequest() async throws -> PresentedPalette {
        let sidebar = LeoSidebarModel()
        let hostSelection = LeoHostSelection.isolatedForTesting()
        let actions = LeoAgentActions(
            daemon: UnusedDaemon(), cli: .recordingForTests(), model: sidebar, hostSelection: hostSelection,
            processRunner: LeoRecordingTemplateRunner(), refresh: {}
        )
        let router = LeoNewSurfaceRouter(
            attach: { _, _, _ in .success(()) },
            openPlainShell: { _ in .success(()) },
            presentSpawn: { _, complete in complete(nil) }
        )
        let panel = LeoAgentPalettePanel()
        let presentation = LeoPickerPresentation(
            window: window, router: router, sidebar: sidebar, hostSelection: hostSelection, actions: actions, panel: panel
        )
        let request = LeoSurfaceRequest(origin: origin, disposition: .content)
        router.begin(request)
        presentation.present(request: request)
        try #require(await eventually { panel.isKeyWindow }, "the palette never became key")
        return PresentedPalette(presentation: presentation, panel: panel)
    }

    /// The window takes key status back once the palette is gone; without
    /// it the cursor check in `expectSettled` (`focused == isKeyWindow`)
    /// passes for any pane.
    func requireKeyAgain(_ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try #require(await eventually { window.isKeyWindow }, "never key again: \(describe()) \(comment)", sourceLocation: sourceLocation)
    }

    /// `expected` becomes the first responder and stays it once every
    /// focus move still pending has landed; then it alone draws focused
    /// (as long as the window is key).
    func expectSettled(
        on expected: Ghostty.SurfaceView,
        _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let isFirstResponder = { window.firstResponder === expected }
        try #require(await eventually(isFirstResponder), "never first responder: \(describe()) \(comment ?? "")", sourceLocation: sourceLocation)
        try? await Task.sleep(for: Self.pendingFocusMovesLand)
        #expect(isFirstResponder(), "focus moved on: \(describe()) \(comment ?? "")", sourceLocation: sourceLocation)
        #expect(controller.focusedSurface === expected, "the window's focused surface \(comment ?? "")", sourceLocation: sourceLocation)
        #expect(expected.focused == window.isKeyWindow, "its cursor: \(describe()) \(comment ?? "")", sourceLocation: sourceLocation)
        let others = controller.surfaceTree.filter { $0 !== expected && $0.focused }
        #expect(others.isEmpty, "another pane draws focused: \(describe()) \(comment ?? "")", sourceLocation: sourceLocation)
    }

    private func row(_ handle: AttachmentHandle) throws -> Row {
        Row(handle: handle, surface: try #require(controller.surfaceTree.first { $0.id == handle.surfaceID }))
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + Self.timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func describe() -> String {
        let responder = window.firstResponder.map { "\(type(of: $0))" } ?? "nil"
        let panes = controller.surfaceTree.map { "\($0.id.uuidString.prefix(4)) focused=\($0.focused)" }
        return "key=\(window.isKeyWindow) firstResponder=\(responder) panes=\(panes)"
    }

    enum FixtureError: Error {
        case noWindow
    }
}

/// A palette shown by its `LeoPickerPresentation`, which the panel holds
/// only weakly (through its commit closure), so it is kept here.
@MainActor
private struct PresentedPalette {
    let presentation: LeoPickerPresentation
    let panel: LeoAgentPalettePanel

    /// The key the user presses, through the panel's own key handling
    /// rather than `panel.dismiss()`.
    func pressEscape() throws {
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ))
        panel.keyDown(with: escape)
    }
}

private final class SidebarStandIn: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// The palette's actions need a daemon; nothing here reaches it.
private struct UnusedDaemon: LeoDaemonClient {
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
