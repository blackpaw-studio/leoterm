import Foundation
import LeoKit

/// Posts a local notification when an agent asks for a handoff
/// (`browser_handoff`), so Evan notices even when its row isn't on screen.
/// Watches every browser the presence has, now and as they open; posts each
/// request once. Goes through the same `LeoNotificationPosting` as the
/// attention notifications; `isEnabled` is their opt-in.
@MainActor final class LeoHandoffNotifier {
    private let presence: any LeoAgentBrowserPresence
    private let poster: any LeoNotificationPosting
    private let isEnabled: () -> Bool
    /// The name an agent's row shows; nil titles the notification by its raw name.
    private let displayName: (LeoAgentRow.ID) -> String?
    private var watches: [LeoAgentBrowserKey: () -> Void] = [:]
    private var lastRequest: [LeoAgentBrowserKey: String] = [:]
    private var stopObservingPresence: (() -> Void)?
    /// The latest post, for a test to wait on.
    private(set) var posting: Task<Void, Never>?

    init(presence: any LeoAgentBrowserPresence, poster: any LeoNotificationPosting, isEnabled: @escaping () -> Bool = { true },
         displayName: @escaping (LeoAgentRow.ID) -> String? = { _ in nil }) {
        self.displayName = displayName
        self.presence = presence
        self.poster = poster
        self.isEnabled = isEnabled
        stopObservingPresence = presence.observe { [weak self] change in
            switch change {
            case .opened(let key): self?.watch(key)
            case .closed(let key): self?.unwatch(key)
            }
        }
        presence.keys.forEach(watch)
    }

    private func watch(_ key: LeoAgentBrowserKey) {
        guard watches[key] == nil, let source = presence.browser(for: key) else { return }
        watches[key] = source.control.observe { [weak self] state in self?.noticed(state, in: key) }
        noticed(source.control.state, in: key)
    }

    private func unwatch(_ key: LeoAgentBrowserKey) {
        watches.removeValue(forKey: key)?()
        lastRequest[key] = nil
    }

    private func noticed(_ state: LeoBrowserControl, in key: LeoAgentBrowserKey) {
        guard let handoff = state.pendingHandoff, lastRequest[key] != handoff.requestID else { return }
        lastRequest[key] = handoff.requestID
        guard isEnabled() else { return }
        let id = LeoAgentRow.ID(host: key.host, name: key.agent)
        let notification = LeoAttentionNotification(
            handoffFrom: id, displayName: displayName(id), requestID: handoff.requestID, message: handoff.message
        )
        let previous = posting
        posting = Task { [poster] in
            await previous?.value
            await poster.post(notification)
        }
    }
}
