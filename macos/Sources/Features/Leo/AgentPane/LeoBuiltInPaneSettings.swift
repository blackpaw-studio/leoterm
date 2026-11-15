import Combine
import Foundation

/// The agent pane's built-in tabs the user can turn off, app-wide. One
/// instance is shared by every window's pane and by Settings ▸ Plugins, so a
/// switch in Settings reaches open windows at once. It publishes its own
/// writes: there is no defaults observer, so nothing here can be called back
/// from inside another defaults write.
@MainActor final class LeoBuiltInPaneSettings: ObservableObject {
    enum Keys {
        static let showsTerminalTab = "leo.agentPane.showsTerminalTab"
    }

    @Published private(set) var showsTerminalTab: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // Off only when explicitly turned off: a missing or wrong-typed value is the default, on.
        showsTerminalTab = defaults.object(forKey: Keys.showsTerminalTab) as? Bool ?? true
    }

    func setShowsTerminalTab(_ shown: Bool) {
        guard shown != showsTerminalTab else { return }
        defaults.set(shown, forKey: Keys.showsTerminalTab)
        showsTerminalTab = shown
    }
}
