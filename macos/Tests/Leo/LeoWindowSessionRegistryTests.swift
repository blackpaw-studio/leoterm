import AppKit
import Foundation
import Testing

@testable import Ghostty

@MainActor struct LeoWindowSessionRegistryTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "LeoWindowSessionRegistryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Review finding: `LeoRuntime.makeWindowSession(for:)` wires
    /// `session.openPicker` with a closure stored *on* the session -- if
    /// that closure captures `session` itself (instead of just its `id`),
    /// the session retains a closure that retains the session, and it
    /// never deallocates. This reproduces the exact pattern the fix uses.
    @Test func sessionDeallocatesEvenWithOpenPickerWiredViaCapturedID() {
        let registry = LeoWindowSessionRegistry()
        weak var weakSession: LeoWindowSession?
        do {
            let session = registry.makeSession(defaults: makeDefaults())
            let sessionID = session.id
            session.openPicker = { _ in _ = sessionID }
            weakSession = session
            #expect(weakSession != nil)
        }
        #expect(weakSession == nil)
    }

    /// Review finding: a window's requests must be invalidated once its
    /// session unregisters. `report()` is the only place the registry
    /// notices a session has deallocated (no deinit hook), so this is
    /// reconciled the next time `report()` runs for any reason.
    @Test func onUnregisteredFiresOnceForADeallocatedSessionOnNextReport() {
        let registry = LeoWindowSessionRegistry()
        var unregistered: [LeoWindowID] = []
        registry.onUnregistered = { unregistered.append($0) }

        var goneID: LeoWindowID!
        do {
            let session = registry.makeSession(defaults: makeDefaults())
            goneID = session.id
        }

        #expect(unregistered.isEmpty)
        let stillAlive = registry.makeSession(defaults: makeDefaults())
        #expect(unregistered == [goneID])

        // Reconciling again (with `stillAlive` still retained) must not
        // re-report the same id, nor report `stillAlive` itself.
        _ = registry.makeSession(defaults: makeDefaults())
        #expect(unregistered == [goneID])
        _ = stillAlive
    }

    /// Review finding: `LeoRuntime` previously relied entirely on
    /// `onUnregisteredFiresOnceForADeallocatedSessionOnNextReport`'s lazy
    /// reconciliation to invalidate a closed window's router state and
    /// palette presentation -- which may not run for a long time (or ever,
    /// for a single-window quit). `LeoWindowSession.onWindowWillClose` is
    /// the prompt path: it must fire synchronously from the window's own
    /// close, independent of any other session's state changing.
    @Test func onWindowWillCloseFiresPromptlyWhenTheWindowCloses() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let session = LeoWindowSession(window: window, defaults: makeDefaults())
        var closeCount = 0
        session.onWindowWillClose = { closeCount += 1 }

        // Posts the exact notification `LeoWindowSession` observes -- not
        // `window.close()`, which drives the full AppKit close animation/
        // window-server round trip and hangs without a pumped run loop.
        // The observer is registered with `queue: .main`, which delivers via
        // `OperationQueue.main` (an async hop even when posted from the main
        // thread) -- so this polls briefly instead of asserting immediately.
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        let deadline = Date().addingTimeInterval(2)
        while closeCount == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(closeCount == 1)
    }
}
