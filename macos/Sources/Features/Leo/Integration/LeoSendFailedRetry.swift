import Foundation
import LeoKit
import OSLog
import UserNotifications

/// Posts a Leo-made local notification (a failed "Tell an agent" send).
typealias LeoLocalNotificationPost = @Sendable (LeoChatLocalNotification) async -> Void

/// Handles the Retry button on a "couldn't reach" notification: resends the
/// original text through the same sender. A retry that fails again posts the
/// notification again with the same text, so the message is never dropped.
struct LeoSendFailedRetry: Sendable {
    let sender: LeoAgentMessageSender
    let post: LeoLocalNotificationPost

    /// Whether `actionIdentifier` was a Retry this handled (the caller then
    /// leaves the notification alone). The resend runs in the background.
    @discardableResult
    func handle(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> Bool {
        guard actionIdentifier == LeoChatNotificationActions.retryActionID else { return false }
        guard case .retry(let target, let text)? = LeoChatNotificationActions.response(
            actionIdentifier: actionIdentifier, userText: nil, userInfo: userInfo) else { return true }
        Task { await retry(target, text: text) }
        return true
    }

    func retry(_ target: LeoPushTarget, text: String) async {
        guard let host = LeoAgentMachineID.host(for: target.daemonID) else { return }
        let agent = LeoAgentTarget(machineID: target.daemonID, machineName: LeoAgentMachineID.name(for: host), agent: target.agent)
        let result = await sender.send(agent, text: text)
        if let payload = result.retryPayload { await repost(payload) }
    }

    private func repost(_ payload: LeoAgentRetryPayload) async {
        await post(LeoChatNotificationActions.sendFailedContent(payload))
    }
}

extension LeoSendFailedRetry {
    /// The send-failed category, for the app's one `setNotificationCategories`
    /// call (which replaces every category, so it can't be registered apart).
    static var category: UNNotificationCategory? {
        LeoChatNotificationActions.staticCategories
            .first { $0.identifier == LeoChatNotificationActions.sendFailedCategoryID }?.notificationCategory
    }

    /// The production poster: asks for alert permission, then adds the request.
    static let postToNotificationCenter: LeoLocalNotificationPost = { notification in
        let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.categoryIdentifier = notification.categoryID
        content.userInfo = notification.userInfo
        content.threadIdentifier = notification.threadIdentifier
        do {
            _ = try await center.requestAuthorization(options: [.alert])
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            logger.error("send-failed notification: \(error.localizedDescription, privacy: .public)")
        }
    }
}
