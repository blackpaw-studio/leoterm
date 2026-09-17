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
            session.openPicker = { _ = sessionID }
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
}
