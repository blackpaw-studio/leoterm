import AppKit
import Testing

@testable import Ghostty

/// B-016: the host's focused attachment is the surface that really has
/// keyboard focus (the key window's first responder), not merely the
/// controller's remembered `focusedSurface`; the viewed attachment is the
/// latter. Drives a real `TerminalController`, so it is skipped -- visibly
/// -- without the app's real `Ghostty.App`.
@MainActor struct GhosttyAttachTabHostFocusTests {
    @Test(.enabled("needs the test host app's Ghostty.App") { await MainActor.run { Self.ghostty != nil } })
    func focusFollowsTheFirstResponderNotJustTheFocusedSurface() async throws {
        let ghostty = try #require(Self.ghostty)
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
        #expect(host.viewedHandle(isActive: true, keyWindow: window) == handle)

        // Selecting a sidebar row: the list takes first responder, the
        // controller still remembers the surface as `focusedSurface`.
        let sidebar = FirstResponderView()
        window.contentView?.addSubview(sidebar)
        window.makeFirstResponder(sidebar)
        #expect(controller.focusedSurface === surface)
        #expect(host.focusedHandle(isActive: true, keyWindow: window) == nil)
        #expect(host.viewedHandle(isActive: true, keyWindow: window) == handle, "the tab beside the sidebar is still in view")

        window.makeFirstResponder(surface)
        #expect(host.focusedHandle(isActive: true, keyWindow: window) == handle, "clicking back into the terminal")
        #expect(host.focusedHandle(isActive: false, keyWindow: window) == nil)
        #expect(host.viewedHandle(isActive: false, keyWindow: window) == nil)
    }

    /// B-019: the order the host reports focus on `lifecycleEvents`.
    /// Viewing comes before focus (a `.focusChanged` onto an attachment
    /// implies it is viewed), and moving keyboard focus to the sidebar only
    /// clears focus -- the tab beside it is still viewed.
    @Test(.enabled("needs the test host app's Ghostty.App") { await MainActor.run { Self.ghostty != nil } })
    func focusReportsArriveViewingFirstAndTheSidebarOnlyClearsFocus() async throws {
        let ghostty = try #require(Self.ghostty)
        let controller = TerminalController.leoNewPlaceholderWindow(ghostty)
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let registry = LeoWindowSessionRegistry()
        let suite = "GhosttyAttachTabHostFocusTests.\(UUID().uuidString)"
        let session = registry.makeSession(
            window: window, controller: controller, defaults: try #require(UserDefaults(suiteName: suite))
        )
        let appState = AppStateBox(isActive: true, keyWindow: window)
        let host = GhosttyAttachTabHost(registry: registry, requestConfigStore: LeoRequestConfigStore()) {
            GhosttyAttachTabHost.AppFocusState(isActive: appState.isActive, keyWindow: appState.keyWindow)
        }
        let recorder = FocusReportRecorder(host)
        defer { recorder.stop() }
        let handle = try host.fillPlaceholder(command: "", workingDirectory: nil, origin: session.id, surfaceID: nil, requestID: UUID())
        let surface = try #require(controller.surfaceTree.first { $0.id == handle.surfaceID })
        try await waitUntilInWindow(surface, window)
        window.makeFirstResponder(surface)
        _ = try await recorder.reports(during: {})
        #expect(host.focusedHandle == handle)

        let sidebar = FirstResponderView()
        window.contentView?.addSubview(sidebar)
        let toSidebar = try await recorder.reports { window.makeFirstResponder(sidebar) }
        #expect(toSidebar == [.focusChanged(nil)], "the sidebar takes keyboard focus; the tab stays in view")

        appState.isActive = false
        let deactivated = try await recorder.reports { window.makeFirstResponder(surface) }
        #expect(deactivated == [.viewingChanged(nil), .focusSuspended])

        appState.isActive = true
        let reactivated = try await recorder.reports { controller.focusedSurface = surface }
        #expect(reactivated == [.viewingChanged(handle), .focusChanged(handle)], "viewing is reported before focus")
    }

    @Test func anInactiveAppOrNoKeyWindowSuspendsFocusRatherThanClearingIt() {
        let host = GhosttyAttachTabHost(registry: LeoWindowSessionRegistry(), requestConfigStore: LeoRequestConfigStore())
        let window = NSWindow()
        #expect(host.focusEvent(isActive: false, keyWindow: window) == .focusSuspended)
        #expect(host.focusEvent(isActive: true, keyWindow: nil) == .focusSuspended)
        #expect(host.focusEvent(isActive: true, keyWindow: window) == .focusChanged(nil), "a non-terminal key window")
    }

    private static var ghostty: Ghostty.App? { (NSApp.delegate as? AppDelegate)?.ghostty }

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

@MainActor private final class AppStateBox {
    var isActive: Bool
    var keyWindow: NSWindow?

    init(isActive: Bool, keyWindow: NSWindow?) {
        self.isActive = isActive
        self.keyWindow = keyWindow
    }
}

/// Drains a host's `lifecycleEvents`, keeping the focus reports, and
/// returns the ones an action produced once the host has settled.
@MainActor private final class FocusReportRecorder {
    private let host: GhosttyAttachTabHost
    private var received: [AttachLifecycleEvent] = []
    private var drain: Task<Void, Never>?

    init(_ host: GhosttyAttachTabHost) {
        self.host = host
        drain = Task { [weak self, events = host.lifecycleEvents] in
            for await event in events where Self.isFocusReport(event) {
                self?.received.append(event)
            }
        }
    }

    func stop() { drain?.cancel() }

    /// Runs `action`, lets the main queue turn (a surface losing focus is
    /// reported on the next turn), then waits until every report the host
    /// has yielded has been received.
    func reports(during action: () -> Void) async throws -> [AttachLifecycleEvent] {
        let start = host.focusReportCount
        action()
        for _ in 0..<5 { try await Task.sleep(nanoseconds: 20_000_000) }
        for _ in 0..<50 where received.count < host.focusReportCount {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(received.count == host.focusReportCount, "every yielded focus report was received")
        return Array(received[start...])
    }

    private static func isFocusReport(_ event: AttachLifecycleEvent) -> Bool {
        switch event {
        case .focusChanged, .viewingChanged, .focusSuspended: true
        default: false
        }
    }
}
