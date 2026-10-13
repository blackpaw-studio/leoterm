import Foundation

/// The agent a push is about.
public struct LeoPushTarget: Equatable, Hashable, Sendable {
    public let daemonID: String
    public let agent: String

    public init(daemonID: String, agent: String) {
        self.daemonID = daemonID
        self.agent = agent
    }
}

/// What the Notification Service Extension shows in place of the relay's
/// generic alert.
public struct LeoPushAlert: Equatable, Sendable {
    /// The agent's name.
    public let title: String
    /// The state line; empty when it is the banner body instead, so one
    /// line never shows twice.
    public let subtitle: String
    public let body: String
    public let target: LeoPushTarget
    /// The daemon's push kind: an attention state, or `chat`.
    public var kind: String = ""
    /// The chat message the push is about, if any.
    public var chat: LeoPushChat?

    /// The notification's `userInfo` after decryption: the target, the
    /// kind and any chat message id.
    public var userInfo: [String: String] {
        var info = [
            LeoPushNotification.daemonIDKey: target.daemonID, LeoPushNotification.agentKey: target.agent,
            LeoPushNotification.kindKey: kind,
        ]
        if let messageID = chat?.messageID { info[LeoPushNotification.messageIDKey] = messageID }
        return info
    }

    /// Groups an agent's notifications into one thread.
    public var threadIdentifier: String { "\(target.daemonID)/\(target.agent)" }
}

/// What a push says about a Leo Chat message.
public struct LeoPushChat: Equatable, Sendable {
    public let messageID: String?
    public let messageKind: String?
    public let options: [LeoChatOption]
    /// An `ask`'s input type; nil from daemons before leo #268.
    public let inputType: String?

    public init(messageID: String?, messageKind: String?, options: [LeoChatOption], inputType: String? = nil) {
        self.messageID = messageID
        self.messageKind = messageKind
        self.options = options
        self.inputType = inputType
    }
}

/// Reads Leo pushes: `{"aps": {…generic alert…}, "c": ciphertext}` from the
/// relay, and the `{daemon_id, agent}` userInfo the extension leaves behind.
public enum LeoPushNotification {
    public static let ciphertextKey = "c"
    public static let daemonIDKey = "daemon_id"
    public static let agentKey = "agent"
    public static let kindKey = "kind"
    public static let messageIDKey = "message_id"
    public static let chatKind = "chat"

    /// The decrypted alert, or nil when anything is off (the caller then
    /// leaves the generic alert alone), including a push from a daemon not
    /// in `pairedDaemonIDs`: one this phone forgot keeps pushing until its
    /// registration is cleaned up, and stays generic meanwhile.
    public static func alert(userInfo: [AnyHashable: Any], key: LeoPushKey, pairedDaemonIDs: Set<String>) -> LeoPushAlert? {
        guard let ciphertext = userInfo[ciphertextKey] as? String,
              let payload = try? LeoPushCipher.open(ciphertext, key: key),
              pairedDaemonIDs.contains(payload.daemonID), !payload.agent.isEmpty else { return nil }
        let hasDetail = !payload.body.isEmpty
        let isChat = payload.kind == chatKind || payload.messageID != nil
        return LeoPushAlert(
            title: payload.agent,
            subtitle: hasDetail ? payload.title : "",
            body: hasDetail ? payload.body : payload.title,
            target: LeoPushTarget(daemonID: payload.daemonID, agent: payload.agent),
            kind: payload.kind,
            chat: isChat ? LeoPushChat(
                messageID: payload.messageID, messageKind: payload.messageKind, options: payload.options, inputType: payload.inputType
            ) : nil
        )
    }

    /// Whether a delivered notification is about a chat thread (a `chat`
    /// push, or an attention push carrying a chat message).
    public static func isChat(userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[kindKey] as? String == chatKind || (userInfo[messageIDKey] as? String).map { !$0.isEmpty } == true
    }

    /// The agent a tapped notification opens; nil for one the extension
    /// could not decrypt.
    public static func target(userInfo: [AnyHashable: Any]) -> LeoPushTarget? {
        guard let daemonID = userInfo[daemonIDKey] as? String, !daemonID.isEmpty,
              let agent = userInfo[agentKey] as? String, !agent.isEmpty else { return nil }
        return LeoPushTarget(daemonID: daemonID, agent: agent)
    }
}
