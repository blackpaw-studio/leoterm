import Foundation

/// The per-device "Agent browser" switch (C7), on by default and stored
/// under `defaultsKey`. Off, no machine's agents can use the browser tools
/// and every agent browser closes; its data stores stay. A Mac before
/// macOS 14 can't run the browser, so it reads as off there.
@MainActor final class LeoAgentBrowserSetting: ObservableObject {
    static let defaultsKey = "leo.agentBrowser.enabled"

    /// The browser needs `WKWebsiteDataStore(forIdentifier:)` (macOS 14).
    nonisolated static var isPlatformSupported: Bool {
        if #available(macOS 14, *) { true } else { false }
    }

    @Published var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            defaults.set(isOn, forKey: Self.defaultsKey)
        }
    }

    let isSupported: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults, isSupported: Bool = LeoAgentBrowserSetting.isPlatformSupported) {
        self.defaults = defaults
        self.isSupported = isSupported
        isOn = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    /// Whether agent browsers run on this Mac.
    var isEnabled: Bool { isSupported && isOn }
}
