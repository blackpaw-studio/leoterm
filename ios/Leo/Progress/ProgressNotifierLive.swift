import ComposableArchitecture
import LeoFeatures
import LeoKit
import UserNotifications

extension ProgressNotifierClient: @retroactive DependencyKey {
    /// A local notification: pushes can't carry a finish while the app is
    /// suspended (out of scope), so this fires only while events flow. Its
    /// userInfo matches a push's, so a tap opens the agent the same way.
    public static var liveValue: ProgressNotifierClient {
        ProgressNotifierClient(post: { notification in
            let content = UNMutableNotificationContent()
            content.title = notification.agentName
            content.body = switch notification.outcome {
            case .succeeded: String(localized: "Finished: \(notification.taskTitle)")
            case .failed: String(localized: "Failed: \(notification.taskTitle)")
            }
            content.sound = .default
            content.threadIdentifier = "progress.\(notification.ref.daemonID).\(notification.ref.name)"
            content.userInfo = [
                LeoPushNotification.daemonIDKey: notification.ref.daemonID,
                LeoPushNotification.agentKey: notification.ref.name,
            ]
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        })
    }
}
