import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

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
    @Test(.requiresActiveHost) func dismissingThePaletteGivesFocusBackToTheTerminal() async throws {
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
    @Test(.requiresActiveHost) func aSplitChosenInThePaletteKeepsFocusOnceThePaletteCloses() async throws {
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

    private static let timeout: Duration = .seconds(5)

    /// Just past the longest `Ghostty.moveFocus` retry chain for a move
    /// queued with no initial delay: retries at 50, 100, 200 and 400 ms
    /// (SurfaceView.swift) end 750 ms after it; the fifth, 800 ms, is
    /// refused by `maxDelay` (0.5 s). The one caller with an initial delay
    /// (BaseTerminalController.swift:808, 0.1 s) finishes by 700 ms. A
    /// future caller with an initial delay under 50 ms would run past this.
    private static let focusRetryChain: TimeInterval = 0.8

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
        panel.present(parent: window, model: LeoAgentPaletteModel(), onCommit: { _ in }, onRetry: { _ in }, onResignKey: {})
        try #require(await eventually { panel.isKeyWindow }, "the palette never became key \(LeoTestHostActivation.focusDiagnostic())")
        return panel
    }

    /// The palette as ⌘O shows it: a real `LeoPickerPresentation` over
    /// this window driving the real panel, for a request it has begun.
    func presentPaletteForRequest() async throws -> PresentedPalette {
        let sidebar = LeoSidebarModel()
        let actions = LeoAgentActions(
            clients: FakeMachineClients(daemon: UnusedDaemon()), cli: .recordingForTests(), model: sidebar, processRunner: LeoRecordingTemplateRunner(), refresh: {}
        )
        let router = LeoNewSurfaceRouter(
            attach: { _, _, _ in .success(()) },
            openPlainShell: { _ in .success(()) },
            presentSpawn: { _, complete in complete(nil) }
        )
        let panel = LeoAgentPalettePanel()
        let presentation = LeoPickerPresentation(
            window: window, router: router, sidebar: sidebar, machines: .isolatedForTesting(), actions: actions, panel: panel
        )
        let request = LeoSurfaceRequest(origin: origin, disposition: .content)
        router.begin(request)
        presentation.present(request: request)
        try #require(await eventually { panel.isKeyWindow }, "the palette never became key \(LeoTestHostActivation.focusDiagnostic())")
        return PresentedPalette(presentation: presentation, panel: panel)
    }

    /// The window takes key status back once the palette is gone; without
    /// it the cursor check in `expectSettled` (`focused == isKeyWindow`)
    /// passes for any pane.
    func requireKeyAgain(_ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try #require(await eventually { window.isKeyWindow }, "never key again: \(describe()) \(comment)", sourceLocation: sourceLocation)
    }

    /// `expected` becomes the first responder, the window's focused surface
    /// and (as long as the window is key) the only pane drawing focused, and
    /// it stays so.
    /// `Ghostty.moveFocus` lands on `asyncAfter` timers, so the state is
    /// polled for rather than read after a fixed wait. A poll cannot show
    /// that focus stays put: a stale `moveFocus` to another pane, queued
    /// before the settle, may still be pending and would steal it back. So
    /// once settled, a main-queue timer past the whole retry chain is
    /// awaited. Without a main-thread stall every retry has fired before it
    /// resumes: the chain's last deadline (750 ms) precedes the drain's
    /// (800 ms) and GCD never fires early. Each retry computes its next
    /// deadline when it fires, so a stall mid-chain can push a later retry
    /// past the drain (accepted risk, B-173). A wall-clock sleep gives even
    /// weaker ordering than a timer on the queue the retries run on.
    func expectSettled(
        on expected: Ghostty.SurfaceView,
        _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let isSettled = {
            window.firstResponder === expected
                && controller.focusedSurface === expected
                && expected.focused == window.isKeyWindow
                && !controller.surfaceTree.contains { $0 !== expected && $0.focused }
        }
        try #require(await eventually { window.firstResponder === expected }, "never first responder: \(describe()) \(comment ?? "")", sourceLocation: sourceLocation)
        // The result is deliberately dropped: the #expects below report
        // which part of the state is wrong, which a bare timeout would not.
        _ = await eventually(isSettled)
        await drainFocusRetries()
        #expect(window.firstResponder === expected, "focus moved on: \(describe()) \(comment ?? "")", sourceLocation: sourceLocation)
        #expect(controller.focusedSurface === expected, "the window's focused surface \(comment ?? "")", sourceLocation: sourceLocation)
        #expect(expected.focused == window.isKeyWindow, "its cursor: \(describe()) \(comment ?? "")", sourceLocation: sourceLocation)
        let others = controller.surfaceTree.filter { $0 !== expected && $0.focused }
        #expect(others.isEmpty, "another pane draws focused: \(describe()) \(comment ?? "")", sourceLocation: sourceLocation)
    }

    private func drainFocusRetries() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusRetryChain) { continuation.resume() }
        }
    }

    private func row(_ handle: AttachmentHandle) throws -> Row {
        Row(handle: handle, surface: try #require(controller.surfaceTree.first { $0.id == handle.surfaceID }))
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + Self.timeout
        while !condition(), ContinuousClock.now < deadline {
            LeoTestHostActivation.requestForeground()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func describe() -> String {
        let responder = window.firstResponder.map { "\(type(of: $0))" } ?? "nil"
        let panes = controller.surfaceTree.map { "\($0.id.uuidString.prefix(4)) focused=\($0.focused)" }
        return "key=\(window.isKeyWindow) firstResponder=\(responder) panes=\(panes) \(LeoTestHostActivation.focusDiagnostic())"
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
