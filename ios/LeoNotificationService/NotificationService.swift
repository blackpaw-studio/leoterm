import LeoKit
import UserNotifications

/// Decrypts a Leo push: the relay's generic "An agent needs you" becomes the
/// agent's name, its state line and the detail, grouped per agent, with
/// Leo Chat reply/answer actions when it is about a chat message. Anything that goes wrong (no key yet, a
/// key the daemon doesn't have, a tampered payload) leaves the generic
/// alert as it arrived, as does a push from a daemon that isn't paired (a
/// forgotten one whose registration hasn't been cleaned up yet). Decryption is synchronous, so the extension never
/// reaches `serviceExtensionTimeWillExpire` with work outstanding.
final class NotificationService: UNNotificationServiceExtension {
    private let store = LeoPushSharedStore()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let paired = (try? store.loadPairedDaemonIDs()) ?? []
        guard let (content, category) = Self.decrypted(request.content, key: try? store.loadKey(), pairedDaemonIDs: paired) else {
            contentHandler(request.content)
            return
        }
        // An ask's buttons are its choices: register its category before
        // the notification shows. The static ones the app registered.
        guard let category, category.identifier.hasPrefix(LeoChatNotificationActions.askCategoryPrefix) else {
            contentHandler(content)
            return
        }
        // Content and handler stay on this one callback path.
        nonisolated(unsafe) let (decrypted, handler) = (content, contentHandler)
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            let others = existing.filter { $0.identifier != category.identifier }
            UNUserNotificationCenter.current().setNotificationCategories(others.union([category.notificationCategory]))
            handler(decrypted)
        }
    }

    /// The decrypted content and, for a chat push, its action category.
    static func decrypted(
        _ content: UNNotificationContent, key: LeoPushKey?, pairedDaemonIDs: Set<String>
    ) -> (UNNotificationContent, LeoChatNotificationCategory?)? {
        guard let key, let alert = LeoPushNotification.alert(userInfo: content.userInfo, key: key, pairedDaemonIDs: pairedDaemonIDs),
              let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return nil }
        mutable.title = alert.title
        mutable.subtitle = alert.subtitle
        mutable.body = alert.body
        mutable.userInfo = alert.userInfo
        mutable.threadIdentifier = alert.threadIdentifier
        let category = LeoChatNotificationActions.category(for: alert)
        if let category { mutable.categoryIdentifier = category.identifier }
        return (mutable, category)
    }
}
