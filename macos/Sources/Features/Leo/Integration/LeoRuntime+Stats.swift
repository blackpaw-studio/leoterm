import AppKit
import Foundation
import LeoKit

/// Feeds `LeoMachineStatsPoller` its inputs.
extension LeoRuntime {
    /// The per-device Stats style (Settings ▸ Machines), stored as a
    /// `LeoStatsStyle` raw value.
    // Literal of S8's `LeoStatsStyle.defaultsKey` (LeoKit, not on this
    // branch); point this at the constant once S8 merges.
    static let statsStyleKey = "LeoStatsStyle"

    static func makeStatsPoller(
        clients: any LeoMachineClientResolving, model: LeoSidebarModel, defaults: UserDefaults
    ) -> LeoMachineStatsPoller {
        LeoMachineStatsPoller(dependencies: .init(
            daemon: { clients.daemon(for: $0) },
            generation: { clients.generation(for: $0) },
            features: { model.features(for: $0) },
            style: { LeoStatsStyle(storedValue: defaults.string(forKey: statsStyleKey)) },
            deliver: { stats, host in model.receiveStats(stats, for: host) }
        ))
    }

    /// App activation, and any defaults write (the Stats style, with no
    /// narrower signal to key on). Observed with no queue and hopped to the
    /// main actor, never `queue: .main`: a defaults write posts
    /// synchronously, and a main-queue observer deadlocks a writer that
    /// holds a lock main is waiting for (see the quit hang, v0.20.0).
    static func observeStatsInputs(
        poller: LeoMachineStatsPoller, defaults: UserDefaults, activation: NotificationCenter
    ) -> [LeoNotificationObservation] {
        let setActive = { @Sendable (active: Bool) in
            Task { @MainActor [weak poller] in poller?.setAppActive(active) }
        }
        return [
            LeoNotificationObservation(center: activation, name: NSApplication.didBecomeActiveNotification) { setActive(true) },
            LeoNotificationObservation(center: activation, name: NSApplication.didResignActiveNotification) { setActive(false) },
            LeoNotificationObservation(center: .default, name: UserDefaults.didChangeNotification) {
                Task { @MainActor [weak poller] in poller?.reconcile() }
            },
        ]
    }
}
