import Foundation
import OSLog
import UserNotifications
import LeoKit

/// The content of one background-agent notification: agent + host title,
/// a body from the state (and reason kind/tool), never terminal text. Only transitions the reducer marked
/// `shouldNotify` (live, into needs_input/finished, not focused) qualify.
struct LeoAttentionNotification: Equatable, Sendable {
    static let identifierPrefix = "studio.blackpaw.leo.attention."
    private static let hostKey = "leoAttentionHost"
    private static let agentKey = "leoAttentionAgent"

    let identifier: String
    let title: String
    let body: String
    let userInfo: [String: String]

    /// `displayName` is the row's shown name; the identifier and userInfo
    /// stay on the raw `id.name`, which is what routes a click.
    init?(_ transition: LeoAttentionTransition, displayName: String? = nil) {
        guard transition.shouldNotify else { return nil }
        switch transition.to {
        case .needsInput:
            // Kind and tool only; `detail` (a path, a command) never leaves the app.
            body = transition.reason.map { LeoStatusPresentation.attentionReason($0).notificationBody } ?? "Needs your input"
        case .finished: body = "Finished"
        case .working, .errored, .unknown: return nil
        }
        let id = transition.id
        identifier = "\(Self.identifierPrefix)\(Self.identifierHostKey(id.host)).\(id.name).\(transition.bootID ?? "-").\(transition.revision)"
        title = Self.title(displayName ?? id.name, host: id.host)
        userInfo = [Self.hostKey: Self.encode(id.host), Self.agentKey: id.name]
    }

    private static func title(_ agent: String, host: LeoHostID) -> String { "\(agent) · \(host.displayName)" }

    /// The agent a clicked notification refers to, or `nil` when it isn't
    /// one of ours.
    static func agent(fromUserInfo userInfo: [AnyHashable: Any]) -> LeoAgentRow.ID? {
        guard let host = userInfo[hostKey] as? String, let name = userInfo[agentKey] as? String else { return nil }
        return LeoAgentRow.ID(host: host.isEmpty ? .local : .remote(host), name: name)
    }

    fileprivate static func identifierHostKey(_ host: LeoHostID) -> String {
        switch host {
        case .local: "local"
        case .remote(let name): "remote.\(name)"
        }
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
/// (host, agent, boot, revision) at most once, and never
/// catches up on states that existed before enabling (the reducer only
/// emits live transitions).
@MainActor final class LeoAttentionController {
    private static let enabledKey = "leo.attentionNotifications.enabled"
    private static let deniedInstructionsShownKey = "leo.attentionNotifications.deniedInstructionsShown"

    private let center: any LeoNotificationPosting
    private let defaults: UserDefaults
    private let showDeniedInstructions: () -> Void
    /// Whether `host` still has a live feed; a batch from any other
    /// machine is late (it was removed or disabled meanwhile).
    private let isLive: (LeoHostID) -> Bool
    /// The latest post per agent. Revisions only grow per name within one
    /// boot, so that is enough to drop repeats; a new boot replaces it. Only
    /// live machines' agents are kept.
    private var lastPosted: [LeoAgentRow.ID: LeoAttentionTransition] = [:]

    init(
        center: any LeoNotificationPosting, defaults: UserDefaults, isLive: @escaping (LeoHostID) -> Bool,
        showDeniedInstructions: @escaping () -> Void
    ) {
        self.center = center
        self.defaults = defaults
        self.isLive = isLive
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

    /// `displayNames` maps agents to the name their row shows; one it omits
    /// is titled by its raw name.
    func handle(_ transitions: [LeoAttentionTransition], displayNames: [LeoAgentRow.ID: String] = [:]) async {
        guard isEnabled else { return }
        for transition in transitions {
            // Batches arrive via unordered tasks, so one can land after its machine left.
            guard isLive(transition.id.host) else { continue }
            guard let notification = LeoAttentionNotification(transition, displayName: displayNames[transition.id]), !alreadyPosted(transition) else { continue }
            lastPosted = lastPosted.filter { isLive($0.key.host) }
            lastPosted[transition.id] = transition
            await center.post(notification)
        }
    }

    private func alreadyPosted(_ transition: LeoAttentionTransition) -> Bool {
        guard let last = lastPosted[transition.id] else { return false }
        return last.bootID == transition.bootID && last.revision >= transition.revision
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

extension LeoAttentionNotification {
    /// The longest handoff message a notification shows.
    private static let handoffBodyLimit = 200

    /// An agent's `browser_handoff`: its own message is the body, so Evan can
    /// tell what it wants without opening the pane. Clicking it opens the
    /// agent's row, like the attention ones.
    init(handoffFrom id: LeoAgentRow.ID, displayName: String? = nil, requestID: String, message: String) {
        identifier = "\(Self.identifierPrefix)handoff.\(Self.identifierHostKey(id.host)).\(id.name).\(requestID)"
        title = Self.title(displayName ?? id.name, host: id.host)
        let collapsed = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        body = collapsed.isEmpty ? "Needs your help in the browser" : String(collapsed.prefix(Self.handoffBodyLimit))
        userInfo = [Self.hostKey: Self.encode(id.host), Self.agentKey: id.name]
    }
}

extension LeoAttentionNotification {
    /// A task that just finished live: "Done: title" or "Failed: title".
    /// Clicking it opens the agent's row, like the attention ones.
    init?(taskFinish finish: LeoTaskFinish, host: LeoHostID, displayName: String? = nil) {
        guard let ended = finish.task.endedAt else { return nil }
        let id = LeoAgentRow.ID(host: host, name: finish.agent)
        let stamp = Int(ended.timeIntervalSince1970 * 1000)
        identifier = "\(Self.identifierPrefix)task.\(Self.identifierHostKey(host)).\(finish.agent).\(finish.task.id).\(stamp)"
        title = Self.title(displayName ?? id.name, host: host)
        body = LeoTaskText.summary(finish.task, etaAt: nil, now: ended)
        userInfo = [Self.hostKey: Self.encode(host), Self.agentKey: finish.agent]
    }
}
