import LeoKit
import UserNotifications

/// Decrypts a Leo push: the relay's generic "An agent needs you" becomes the
/// agent's name and what it needs. Anything that goes wrong (no key yet, a
/// key the daemon doesn't have, a tampered payload) leaves the generic
/// alert as it arrived. Decryption is synchronous, so the extension never
/// reaches `serviceExtensionTimeWillExpire` with work outstanding.
final class NotificationService: UNNotificationServiceExtension {
    private let keyStore = LeoPushKeyStore()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        contentHandler(Self.decrypted(request.content, key: try? keyStore.load()) ?? request.content)
    }

    static func decrypted(_ content: UNNotificationContent, key: LeoPushKey?) -> UNNotificationContent? {
        guard let key, let alert = LeoPushNotification.alert(userInfo: content.userInfo, key: key),
              let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return nil }
        mutable.title = alert.title
        mutable.body = alert.body
        mutable.userInfo = alert.userInfo
        return mutable
    }
}
