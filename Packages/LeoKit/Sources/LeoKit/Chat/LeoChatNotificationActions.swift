import CryptoKit
import Foundation

/// A notification category as plain data: what the app registers and the
/// extension picks for a Leo Chat push. `LeoChatNotificationCategory+UN`
/// turns it into a `UNNotificationCategory`.
public struct LeoChatNotificationCategory: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case button(id: String, title: String, isDestructive: Bool)
        case textInput(id: String, title: String, buttonTitle: String, placeholder: String)

        public var id: String {
            switch self {
            case .button(let id, _, _), .textInput(let id, _, _, _): id
            }
        }
    }

    public let identifier: String
    public let actions: [Action]
}

/// What the user did with a Leo Chat notification action.
public enum LeoChatNotificationResponse: Equatable, Sendable {
    case reply(LeoPushTarget, text: String, replyTo: String?)
    case answer(LeoPushTarget, messageID: String, value: String)
}

/// Notification categories and actions for Leo Chat: a text reply on every
/// chat push, Allow/Deny on permission prompts, and an `ask`'s choices.
public enum LeoChatNotificationActions {
    public static let chatCategoryID = "leo.chat"
    public static let permissionCategoryID = "leo.chat.permission"
    /// An `ask` category is per choice set: `leo.chat.ask.<digest>`.
    public static let askCategoryPrefix = "leo.chat.ask."
    /// An `ask` answered only in the app (radio, checkboxes, text, or no
    /// options to offer): no actions, so tapping opens the thread. A reply
    /// action would send a message that looks like an answer but isn't.
    public static let askOpenCategoryID = "leo.chat.ask-open"
    public static let replyActionID = "leo.chat.reply"
    /// A choice button's id is this prefix plus the choice's value.
    public static let answerPrefix = "leo.chat.answer:"
    /// How many of an `ask`'s choices get a button.
    public static let maximumAskButtons = 4

    public static var staticCategories: [LeoChatNotificationCategory] {
        [
            LeoChatNotificationCategory(identifier: chatCategoryID, actions: [replyAction]),
            LeoChatNotificationCategory(identifier: permissionCategoryID, actions: permissionButtons),
            LeoChatNotificationCategory(identifier: askOpenCategoryID, actions: []),
        ]
    }

    /// The category for a push, or nil for one that isn't about a chat
    /// message (a plain attention push keeps the default actions).
    public static func category(for alert: LeoPushAlert) -> LeoChatNotificationCategory? {
        guard let chat = alert.chat else { return nil }
        let isChatPush = alert.kind == LeoPushNotification.chatKind
        if chat.messageKind == "permission" || (!isChatPush && chat.messageID != nil) {
            return LeoChatNotificationCategory(identifier: permissionCategoryID, actions: permissionButtons)
        }
        if chat.messageKind == "ask" {
            guard chat.messageID != nil, !chat.options.isEmpty, chat.inputType == nil || chat.inputType == LeoChatInput.Kind.buttons.rawValue else {
                return LeoChatNotificationCategory(identifier: askOpenCategoryID, actions: [])
            }
            let choices = chat.options.prefix(maximumAskButtons)
            let buttons = choices.map { LeoChatNotificationCategory.Action.button(id: answerPrefix + $0.value, title: $0.label, isDestructive: false) }
            return LeoChatNotificationCategory(identifier: askCategoryPrefix + digest(choices), actions: buttons + [replyAction])
        }
        return LeoChatNotificationCategory(identifier: chatCategoryID, actions: [replyAction])
    }

    /// Reads a notification action. Nil for the default (tap) and dismiss
    /// actions, an empty reply, or a notification missing what it needs.
    public static func response(actionIdentifier: String, userText: String?, userInfo: [AnyHashable: Any]) -> LeoChatNotificationResponse? {
        guard let target = LeoPushNotification.target(userInfo: userInfo) else { return nil }
        let messageID = (userInfo[LeoPushNotification.messageIDKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if actionIdentifier == replyActionID {
            let text = (userText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .reply(target, text: text, replyTo: messageID)
        }
        if actionIdentifier.hasPrefix(answerPrefix), let messageID {
            return .answer(target, messageID: messageID, value: String(actionIdentifier.dropFirst(answerPrefix.count)))
        }
        return nil
    }

    private static var permissionButtons: [LeoChatNotificationCategory.Action] {
        LeoChatInput.permission.options.map { .button(id: answerPrefix + $0.value, title: $0.label, isDestructive: $0.value == "deny") }
    }

    /// Categories are shared across agents, so the placeholder can't name one.
    private static var replyAction: LeoChatNotificationCategory.Action {
        .textInput(id: replyActionID, title: String(localized: "Reply"), buttonTitle: String(localized: "Send"), placeholder: String(localized: "Message"))
    }

    private static func digest(_ options: ArraySlice<LeoChatOption>) -> String {
        let joined = options.map { "\($0.value)\u{1F}\($0.label)" }.joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(joined.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
