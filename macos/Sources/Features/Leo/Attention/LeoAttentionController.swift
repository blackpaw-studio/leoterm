import Foundation
import OSLog
import UserNotifications

/// The content of one background-agent notification: agent + host title,
/// a fixed body, never terminal text. Only transitions the reducer marked
/// `shouldNotify` (live, into needs_input/finished, not focused) qualify.
struct LeoAttentionNotification: Equatable, Sendable {
    static let identifierPrefix = "studio.blackpaw.leo.attention."
    private static let hostKey = "leoAttentionHost"
    private static let agentKey = "leoAttentionAgent"

    let identifier: String
    let title: String
    let body: String
    let userInfo: [String: String]

    init?(_ transition: LeoAttentionTransition) {
        guard transition.shouldNotify else { return nil }
        switch transition.to {
        case .needsInput: body = "Needs your input"
        case .finished: body = "Finished"
        case .working, .errored, .unknown: return nil
        }
        let id = transition.id
        let hostKey = switch id.host {
        case .local: "local"
        case .remote(let name): "remote.\(name)"
        }
        let scope = "\(transition.bootID ?? "-").\(transition.incarnation)"
        identifier = "\(Self.identifierPrefix)\(hostKey).\(id.name).\(scope).\(transition.revision)"
        title = "\(id.name) · \(id.host.displayName)"
        userInfo = [Self.hostKey: Self.encode(id.host), Self.agentKey: id.name]
    }

    /// The agent a clicked notification refers to, or `nil` when it isn't
    /// one of ours.
    static func agent(fromUserInfo userInfo: [AnyHashable: Any]) -> LeoAgentRow.ID? {
        guard let host = userInfo[hostKey] as? String, let name = userInfo[agentKey] as? String else { return nil }
        return LeoAgentRow.ID(host: host.isEmpty ? .local : .remote(host), name: name)
    }

    private static func encode(_ host: LeoHostID) -> String {
        switch host {
        case .local: ""
        case .remote(let name): name
        }
    }
}

@MainActor protocol LeoNotificationPosting: AnyObject {
    func requestAlertAuthorization() async -> Bool
    func post(_ notification: LeoAttentionNotification) async
}

/// Opt-in notification policy (Agents ▸ Agent Notifications…). `.alert` is
/// requested only from `enable()`; a denial is explained once. Posts each
/// (host, agent, boot, incarnation, revision) at most once, and never
/// catches up on states that existed before enabling (the reducer only
/// emits live transitions).
@MainActor final class LeoAttentionController {
    private static let enabledKey = "leo.attentionNotifications.enabled"
    private static let deniedInstructionsShownKey = "leo.attentionNotifications.deniedInstructionsShown"

    private let center: any LeoNotificationPosting
    private let defaults: UserDefaults
    private let showDeniedInstructions: () -> Void
    /// The latest post per agent. Revisions only grow within one
    /// `(bootID, incarnation)`, so that is enough to drop repeats; a new boot
    /// or incarnation replaces it. Only the current host's agents are kept.
    private var lastPosted: [LeoAgentRow.ID: LeoAttentionTransition] = [:]

    init(center: any LeoNotificationPosting, defaults: UserDefaults, showDeniedInstructions: @escaping () -> Void) {
        self.center = center
        self.defaults = defaults
        self.showDeniedInstructions = showDeniedInstructions
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    func enable() async {
        let granted = await center.requestAlertAuthorization()
        defaults.set(granted, forKey: Self.enabledKey)
        guard !granted, !defaults.bool(forKey: Self.deniedInstructionsShownKey) else { return }
        defaults.set(true, forKey: Self.deniedInstructionsShownKey)
        showDeniedInstructions()
    }

    func disable() { defaults.set(false, forKey: Self.enabledKey) }

    var rememberedPostCount: Int { lastPosted.count }

    func handle(_ transitions: [LeoAttentionTransition]) async {
        guard isEnabled else { return }
        for transition in transitions {
            guard let notification = LeoAttentionNotification(transition), !alreadyPosted(transition) else { continue }
            lastPosted = lastPosted.filter { $0.key.host == transition.id.host }
            lastPosted[transition.id] = transition
            await center.post(notification)
        }
    }

    private func alreadyPosted(_ transition: LeoAttentionTransition) -> Bool {
        guard let last = lastPosted[transition.id] else { return false }
        return last.bootID == transition.bootID && last.incarnation == transition.incarnation
            && last.revision >= transition.revision
    }
}

/// `UNUserNotificationCenter` behind `LeoNotificationPosting`: ordinary
/// `.active` notifications, no sound, no time-sensitive level; Focus/DND is
/// left to the system.
@MainActor final class LeoUserNotificationCenter: LeoNotificationPosting {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    /// Stateless, so constructible as a default argument anywhere.
    nonisolated init() {}

    func requestAlertAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        } catch {
            Self.logger.error("attention notifications: authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func post(_ notification: LeoAttentionNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.userInfo = notification.userInfo
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Self.logger.error("attention notifications: post failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
