import AppKit

/// "Run as server only" (A10): Leo keeps the daemon's supervisor alive with
/// no Dock icon and no windows. The policies are pure so `AppDelegate`'s
/// config reload applies them instead of undoing them.
@MainActor final class LeoServerMode {
    static let defaultsKey = "leo.serverOnly"

    private(set) var isServerOnly: Bool
    private let defaults: UserDefaults
    private let macosHidden: () -> Ghostty.Config.MacHidden
    private let windowCount: () -> Int
    private let applyPolicy: (NSApplication.ActivationPolicy) -> Void
    private let openWindow: () -> Void
    private let activate: () -> Void

    init(
        defaults: UserDefaults,
        macosHidden: @escaping () -> Ghostty.Config.MacHidden,
        windowCount: @escaping () -> Int,
        applyPolicy: @escaping (NSApplication.ActivationPolicy) -> Void,
        openWindow: @escaping () -> Void,
        activate: @escaping () -> Void
    ) {
        self.defaults = defaults
        self.macosHidden = macosHidden
        self.windowCount = windowCount
        self.applyPolicy = applyPolicy
        self.openWindow = openWindow
        self.activate = activate
        isServerOnly = defaults.bool(forKey: Self.defaultsKey)
    }

    nonisolated static func activationPolicy(
        macosHidden: Ghostty.Config.MacHidden, serverOnly: Bool
    ) -> NSApplication.ActivationPolicy {
        serverOnly || macosHidden == .always ? .accessory : .regular
    }

    nonisolated static func quitsAfterLastWindowClosed(config: Bool, serverOnly: Bool) -> Bool {
        config && !serverOnly
    }

    nonisolated static func opensInitialWindow(config: Bool, serverOnly: Bool) -> Bool {
        config && !serverOnly
    }

    /// The policy for the current choice and config, for `AppDelegate`'s
    /// config reload.
    var activationPolicy: NSApplication.ActivationPolicy {
        Self.activationPolicy(macosHidden: macosHidden(), serverOnly: isServerOnly)
    }

    func setServerOnly(_ serverOnly: Bool) {
        guard serverOnly != isServerOnly else { return }
        isServerOnly = serverOnly
        defaults.set(serverOnly, forKey: Self.defaultsKey)
        applyPolicy(activationPolicy)
        guard !serverOnly, windowCount() == 0 else { return }
        openWindow()
        activate()
    }
}
