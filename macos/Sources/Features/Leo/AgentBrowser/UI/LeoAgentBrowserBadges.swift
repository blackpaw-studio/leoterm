import Combine
import LeoKit
import SwiftUI

extension LeoAgentBrowserKey {
    /// The browser a sidebar row stands for: an agent's own, or a dispatch
    /// row's (`dispatch:<id>`, the name its MCP server reports).
    static func row(host: LeoHostID, agent: String, dispatchID: String?) -> Self {
        dispatchID.map { .dispatch(host: host, id: $0) } ?? Self(host: host, agent: agent)
    }
}

extension LeoRowKey {
    /// The agent browser this row shows; terminals and the start screen have none.
    var agentBrowserKey: LeoAgentBrowserKey? {
        guard case .agent(let host, let name, let dispatchID) = self else { return nil }
        return .row(host: host, agent: name, dispatchID: dispatchID)
    }
}

/// Which sidebar rows show the globe: the ones whose agent has a browser.
/// One per window; rows read it from the environment, so a browser opening
/// redraws only the rows that watch it.
@MainActor final class LeoAgentBrowserBadges: ObservableObject {
    @Published private(set) var keys: Set<LeoAgentBrowserKey>
    private var stopObserving: (() -> Void)?

    init(presence: any LeoAgentBrowserPresence) {
        keys = presence.keys
        stopObserving = presence.observe { [weak self, weak presence] _ in
            guard let self, let presence else { return }
            keys = presence.keys
        }
    }

    func isShown(host: LeoHostID, agent: String, dispatchID: String?) -> Bool {
        keys.contains(.row(host: host, agent: agent, dispatchID: dispatchID))
    }
}

private struct LeoAgentBrowserBadgesKey: EnvironmentKey {
    static let defaultValue: LeoAgentBrowserBadges? = nil
}

extension EnvironmentValues {
    /// Nil (no badges) until the app supplies a presence.
    var leoAgentBrowserBadges: LeoAgentBrowserBadges? {
        get { self[LeoAgentBrowserBadgesKey.self] }
        set { self[LeoAgentBrowserBadgesKey.self] = newValue }
    }
}

/// The globe on a row whose agent has a browser open.
struct LeoAgentBrowserBadge: View {
    let host: LeoHostID
    let agent: String
    var dispatchID: String?
    var isSelected = false
    @Environment(\.leoAgentBrowserBadges) private var badges

    var body: some View {
        if let badges {
            Watching(badges: badges, host: host, agent: agent, dispatchID: dispatchID, isSelected: isSelected)
        }
    }

    private struct Watching: View {
        @ObservedObject var badges: LeoAgentBrowserBadges
        let host: LeoHostID
        let agent: String
        let dispatchID: String?
        let isSelected: Bool

        var body: some View {
            if badges.isShown(host: host, agent: agent, dispatchID: dispatchID) {
                Image(systemName: "globe")
                    .font(.caption)
                    .foregroundStyle(LeoInk.secondary.style(isSelected: isSelected))
                    .help("Agent browser open")
                    .accessibilityLabel("Agent browser open")
            }
        }
    }
}
