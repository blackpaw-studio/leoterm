#if DEBUG
import Combine
import Foundation

/// DEBUG builds only: `LEO_FORCE_DISCONNECTED=1` puts the sidebar in the
/// disconnected state (D-061) once its first list has landed, so the
/// banner over dimmed rows can be screenshotted without stopping the real
/// daemon or a tunnel. Retry then reconnects normally.
enum LeoForcedDisconnectFixture {
    static let environmentKey = "LEO_FORCE_DISCONNECTED"
    static let forcedReason = "Forced by LEO_FORCE_DISCONNECTED"

    static func reason(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment[environmentKey] == "1" ? forcedReason : nil
    }

    /// Calls `disconnect` once, the first time `model` shows a connected
    /// list. The returned object holds the subscription; release it to
    /// disarm.
    @MainActor static func arm(model: LeoSidebarModel, reason: String, disconnect: @escaping (String) -> Void) -> AnyObject {
        Arming(model: model, reason: reason, disconnect: disconnect)
    }

    @MainActor private final class Arming {
        private var subscription: AnyCancellable?

        init(model: LeoSidebarModel, reason: String, disconnect: @escaping (String) -> Void) {
            subscription = model.$snapshot
                .first { $0.connectivity == .connected }
                .sink { _ in disconnect(reason) }
        }
    }
}
#endif
