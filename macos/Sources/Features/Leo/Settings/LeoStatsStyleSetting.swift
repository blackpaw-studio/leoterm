import Foundation
import LeoKit

/// The per-device "Stats style" choice, stored under
/// `LeoStatsStyle.defaultsKey`. Observers elsewhere (the sidebar's meters,
/// the stats poller) read the same key from the same defaults.
@MainActor final class LeoStatsStyleSetting: ObservableObject {
    @Published var style: LeoStatsStyle {
        didSet {
            guard style != oldValue else { return }
            defaults.set(style.rawValue, forKey: LeoStatsStyle.defaultsKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        style = LeoStatsStyle(storedValue: defaults.string(forKey: LeoStatsStyle.defaultsKey))
    }
}
