import Foundation
import LeoKit

/// Where the inbox keeps its seen state between launches. Only a daemon
/// without the shared route (local mode) depends on it; a synced host
/// reseeds from its daemon on every connect.
struct LeoInboxSeenPersistence {
    var load: () -> LeoInboxSeenState
    var save: (LeoInboxSeenState) -> Void

    static let none = LeoInboxSeenPersistence(load: { LeoInboxSeenState() }, save: { _ in })

    static func userDefaults(_ defaults: UserDefaults, key: String = "leo.inbox.seen") -> LeoInboxSeenPersistence {
        LeoInboxSeenPersistence(
            load: {
                guard let data = defaults.data(forKey: key), let state = try? JSONDecoder().decode(LeoInboxSeenState.self, from: data) else {
                    return LeoInboxSeenState()
                }
                return state
            },
            save: { state in
                guard let data = try? JSONEncoder().encode(state) else { return }
                defaults.set(data, forKey: key)
            }
        )
    }
}
