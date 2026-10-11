import AppKit
import Testing

@testable import Ghostty

/// B-287: ⌃C in a terminal row interrupts its process, as in stock
/// Ghostty, while the window's sidebar shows and selects that row; and
/// Return still reaches the shell.
///
/// Drives a real start-screen `TerminalController` with its real sidebar,
/// made key as the app's window is; the key goes in through
/// `NSApp.sendEvent`, so it takes AppKit's own path (the window's key
/// equivalents first, then the first responder's `keyDown`). The row's
/// shell is a stand-in that exits on SIGINT or on a line read, never an
/// agent.
///
/// Needs the test host's `Ghostty.App` and `LeoRuntime`; without them the
/// test fails rather than passing silently.
@MainActor @Suite(.serialized)
struct LeoTerminalControlCTests {
    /// The shell runs under `/usr/bin/login`, which reports exit 0
    /// whatever the shell exits with, so the shell leaves marker files
    /// instead: one once it's listening for the key, one when it got it.
    private static func exitsOnInterrupt(_ markers: Markers) -> String {
        "/bin/sh -c 'trap \"touch \\\"\(markers.done.path)\\\"; exit\" INT; touch \"\(markers.ready.path)\"; while :; do sleep 0.1; done'"
    }

    private static func exitsOnLine(_ markers: Markers) -> String {
        "/bin/sh -c 'touch \"\(markers.ready.path)\"; read line && touch \"\(markers.done.path)\"'"
    }

    struct Markers {
        let ready: URL
        let done: URL

        init() {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("leo-b287-\(UUID().uuidString)")
            ready = base.appendingPathExtension("ready")
            done = base.appendingPathExtension("done")
        }

        func remove() {
            for url in [ready, done] { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static let timeout: Duration = .seconds(5)

    @Test func controlCInterruptsAShownTerminalRowsProcess() async throws {
        let marked = try await Self.marks(running: Self.exitsOnInterrupt, afterPressing: .controlC)
        #expect(marked, "the shell exited by its SIGINT trap")
    }

    /// The sidebar's Return (B-049) must not take Return from the shell.
    @Test func returnReachesAShownTerminalRowsProcess() async throws {
        let marked = try await Self.marks(running: Self.exitsOnLine, afterPressing: .return)
        #expect(marked, "the shell read the line Return ended")
    }

    /// Shows a terminal row running `command` in a real window, its row
    /// selected and its sidebar shown, presses `key` in it, and returns
    /// whether the shell left its marker before exiting.
    private static func marks(running command: (Markers) -> String, afterPressing key: Key) async throws -> Bool {
        let markers = Markers()
        defer { markers.remove() }
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty, "the test host has no Ghostty.App")
        try #require(ghostty.readiness == .ready, "the test host's Ghostty.App isn't ready")
        let controller = TerminalController(ghostty, withSurfaceTree: .init(), leoIsPlaceholder: true)
        defer { controller.closeTabImmediately(registerRedo: false) }
        let window = try #require(controller.window)
        let session = try #require(controller.leoSession, "the window has no Leo session (no LeoRuntime?)")
        session.isSidebarVisible = true

        let registry = LeoWindowSessionRegistry()
        let origin = registry.makeSession(window: window, controller: controller, defaults: LeoInMemoryDefaults()).id
        let configs = LeoRequestConfigStore()
        let host = GhosttyAttachContentHost(registry: registry, requestConfigStore: configs)
        let requestID = UUID()
        var config = Ghostty.SurfaceConfiguration()
        config.command = command(markers)
        config.waitAfterCommand = true
        configs.set(config, for: requestID)

        let handle = try host.showInContent(command: "", workingDirectory: nil, origin: origin, requestID: requestID)
        let surface = try #require(controller.surfaceTree.first { $0.id == handle.surfaceID })
        #expect(session.terminals.selection == surface.id, "the shown row is the sidebar's selection")

        window.makeKeyAndOrderFront(nil)
        try #require(await sidebarIsShown(in: window), "the window's sidebar never showed")
        try #require(await eventually { window.isKeyWindow && window.firstResponder === surface }, "never key with the shell focused")

        try #require(await eventually { FileManager.default.fileExists(atPath: markers.ready.path) }, "the shell never started")
        try press(key, in: window)

        try #require(await eventually { surface.childExitedMessage != nil }, "\(key.name) never reached the shell")
        return FileManager.default.fileExists(atPath: markers.done.path)
    }

    struct Key {
        let name: String
        let characters: String
        let charactersIgnoringModifiers: String
        let keyCode: UInt16
        let modifierFlags: NSEvent.ModifierFlags

        static let controlC = Key(name: "⌃C", characters: "\u{3}", charactersIgnoringModifiers: "c", keyCode: 8, modifierFlags: .control)
        static let `return` = Key(name: "Return", characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 36, modifierFlags: [])
    }

    /// `key` as the keyboard sends it: down and up, through the app.
    private static func press(_ key: Key, in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: key.modifierFlags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers, isARepeat: false, keyCode: key.keyCode
            ))
            NSApp.sendEvent(event)
        }
    }

    private static func sidebarIsShown(in window: NSWindow) async -> Bool {
        await eventually {
            window.contentView?.layoutSubtreeIfNeeded()
            guard let split = window.contentView.flatMap(findSplit), let item = split.sidebarItem else { return false }
            return !item.isCollapsed
        }
    }

    private static func findSplit(_ view: NSView) -> LeoSplitViewController? {
        if let split = (view as? NSSplitView)?.delegate as? LeoSplitViewController { return split }
        return view.subviews.lazy.compactMap(findSplit).first
    }

    private static func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

}
