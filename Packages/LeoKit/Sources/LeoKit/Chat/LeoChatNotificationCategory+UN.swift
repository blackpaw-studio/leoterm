#if canImport(UserNotifications)
import UserNotifications

extension LeoChatNotificationCategory {
    /// The category to register with `UNUserNotificationCenter`. Answer
    /// buttons run in the background; a reply opens nothing either.
    public var notificationCategory: UNNotificationCategory {
        let actions: [UNNotificationAction] = actions.map { action in
            switch action {
            case .button(let id, let title, let isDestructive):
                UNNotificationAction(identifier: id, title: title, options: isDestructive ? [.destructive, .authenticationRequired] : [.authenticationRequired])
            case .textInput(let id, let title, let buttonTitle, let placeholder):
                UNTextInputNotificationAction(
                    identifier: id, title: title, options: [.authenticationRequired], textInputButtonTitle: buttonTitle, textInputPlaceholder: placeholder
                )
            }
        }
        return UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [], options: [])
    }
}
#endif
