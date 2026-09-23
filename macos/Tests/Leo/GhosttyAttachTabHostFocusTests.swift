import AppKit
import Testing

@testable import Ghostty

/// B-016: the host's focused attachment is the surface that really has
/// keyboard focus (the key window's first responder), not merely the
/// controller's remembered `focusedSurface`. Drives a real
/// `TerminalController`; bails out (rather than fails) without the app's
/// real `Ghostty.App`, like `GhosttyAttachTabHostRebirthTests`.
@MainActor struct GhosttyAttachTabHostFocusTests {
    @Test func focusFollowsTheFirstResponderNotJustTheFocusedSurface() async throws {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        let controller = TerminalController.leoNewPlaceholderWindow(ghostty)
        defer { controller.window?.close() }
        let registry = LeoWindowSessionRegistry()
        let suite = "GhosttyAttachTabHostFocusTests.\(UUID().uuidString)"
        let session = registry.makeSession(
            window: controller.window, controller: controller, defaults: try #require(UserDefaults(suiteName: suite))
        )
        let host = GhosttyAttachTabHost(registry: registry, requestConfigStore: LeoRequestConfigStore())
        let handle = try host.fillPlaceholder(command: "", workingDirectory: nil, origin: session.id, surfaceID: nil, requestID: UUID())
        let window = try #require(controller.window)
        let surface = try #require(controller.surfaceTree.first { $0.id == handle.surfaceID })

        try await waitUntilInWindow(surface, window)

        #expect(host.focusedHandle(isActive: true, keyWindow: window) == handle)

        // Selecting a sidebar row: the list takes first responder, the
        // controller still remembers the surface as `focusedSurface`.
        let sidebar = FirstResponderView()
        window.contentView?.addSubview(sidebar)
        window.makeFirstResponder(sidebar)
        #expect(controller.focusedSurface === surface)
        #expect(host.focusedHandle(isActive: true, keyWindow: window) == nil)

        window.makeFirstResponder(surface)
        #expect(host.focusedHandle(isActive: true, keyWindow: window) == handle, "clicking back into the terminal")
        #expect(host.focusedHandle(isActive: false, keyWindow: window) == nil)
    }

    /// SwiftUI installs the surface view in the window on a later layout
    /// pass.
    private func waitUntilInWindow(_ view: NSView, _ window: NSWindow) async throws {
        for _ in 0..<50 where view.window !== window {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(view.window === window, "the surface never joined its window")
    }
}

private final class FirstResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
