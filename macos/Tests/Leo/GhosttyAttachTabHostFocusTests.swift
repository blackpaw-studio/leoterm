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
    @Test(
        .enabled("needs the test host app's Ghostty.App") { await MainActor.run { Self.ghostty != nil } },
        .timeLimit(.minutes(1))
    )
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
        // `fillPlaceholder` moves focus asynchronously (retrying until the
        // surface has a window); wait for it to land rather than race it.
        // Contains, not last: the order is what the steps below assert.
        try #require(await recorder.waitUntil { $0.contains(.focusChanged(handle)) }, "focus never reached the surface")
        await recorder.drainMainQueue()
        try #require(await recorder.caughtUp(), "a yielded focus report never arrived")
        #expect(host.focusedHandle == handle)

        let sidebar = FirstResponderView()
        window.contentView?.addSubview(sidebar)
        let toSidebar = try await recorder.reports(1) { window.makeFirstResponder(sidebar) }
        #expect(toSidebar == [.focusChanged(nil)], "the sidebar takes keyboard focus; the tab stays in view")

        appState.isActive = false
        let deactivated = try await recorder.reports(2) { window.makeFirstResponder(surface) }
        #expect(deactivated == [.viewingChanged(nil), .focusSuspended])

        appState.isActive = true
        let reactivated = try await recorder.reports(2) { controller.focusedSurface = surface }
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
    /// pass. Gives up at a deadline; cancellation ends the wait at once.
    private func waitUntilInWindow(_ view: NSView, _ window: NSWindow, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while view.window !== window, ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
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

/// Drains a host's `lifecycleEvents`, keeping the focus reports. Every
/// wait is on received events, bounded by a deadline, and ends early if
/// the test is cancelled -- a missing report fails, it never hangs.
@MainActor private final class FocusReportRecorder {
    private typealias Waiter = (isSatisfied: ([AttachLifecycleEvent]) -> Bool, continuation: CheckedContinuation<Void, Never>)

    private let host: GhosttyAttachTabHost
    private let timeout: Duration
    private var received: [AttachLifecycleEvent] = []
    private var waiters: [UUID: Waiter] = [:]
    private var drain: Task<Void, Never>?

    init(_ host: GhosttyAttachTabHost, timeout: Duration = .seconds(30)) {
        self.host = host
        self.timeout = timeout
        drain = Task { [weak self, events = host.lifecycleEvents] in
            for await event in events where Self.isFocusReport(event) {
                self?.receive(event)
            }
        }
    }

    func stop() {
        drain?.cancel()
        waiters.keys.forEach(resume)
    }

    /// Runs `action` and returns the reports received once `count` of them
    /// have arrived (or the deadline passed), the main queue has drained
    /// every focus callback `action` queued, and each report the host
    /// yielded has arrived -- so a late extra report is counted too. Throws
    /// if a yielded report never arrives: the order check alone would miss
    /// a lost extra.
    func reports(
        _ count: Int, during action: () -> Void, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> [AttachLifecycleEvent] {
        let start = received.count
        action()
        await waitUntil { $0.count >= start + count }
        await drainMainQueue()
        try #require(await caughtUp(), "a yielded focus report never arrived", sourceLocation: sourceLocation)
        return Array(received[start...])
    }

    /// Hops the main queue until two consecutive hops yield no new report
    /// (or the deadline passes): a callback queued before a hop has run
    /// once that hop resumes.
    func drainMainQueue() async {
        let deadline = ContinuousClock.now + timeout
        var quietHops = 0
        while quietHops < 2, ContinuousClock.now < deadline, !Task.isCancelled {
            let before = host.focusReportCount
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            quietHops = host.focusReportCount == before ? quietHops + 1 : 0
        }
    }

    /// Whether every report the host has yielded so far has arrived.
    func caughtUp() async -> Bool {
        await waitUntil { [host] in $0.count >= host.focusReportCount }
    }

    /// Whether the reports received satisfy `isSatisfied` before the
    /// deadline (or cancellation).
    func waitUntil(_ isSatisfied: @escaping ([AttachLifecycleEvent]) -> Bool) async -> Bool {
        guard !isSatisfied(received) else { return true }
        let id = UUID()
        let deadline = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            self?.resume(id)
        }
        defer { deadline.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume() }
                waiters[id] = (isSatisfied, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(id) }
        }
        return isSatisfied(received)
    }

    private func receive(_ event: AttachLifecycleEvent) {
        received.append(event)
        waiters.filter { $0.value.isSatisfied(received) }.keys.forEach(resume)
    }

    private func resume(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }

    private static func isFocusReport(_ event: AttachLifecycleEvent) -> Bool {
        switch event {
        case .focusChanged, .viewingChanged, .focusSuspended: true
        default: false
        }
    }
}
