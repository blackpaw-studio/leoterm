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

    /// The notification's `userInfo` after decryption: just the target.
    public var userInfo: [String: String] {
        [LeoPushNotification.daemonIDKey: target.daemonID, LeoPushNotification.agentKey: target.agent]
    }
}

/// Reads Leo pushes: `{"aps": {…generic alert…}, "c": ciphertext}` from the
/// relay, and the `{daemon_id, agent}` userInfo the extension leaves behind.
public enum LeoPushNotification {
    public static let ciphertextKey = "c"
    public static let daemonIDKey = "daemon_id"
    public static let agentKey = "agent"

    /// The decrypted alert, or nil when anything is off (the caller then
    /// leaves the generic alert alone), including a push from a daemon not
    /// in `pairedDaemonIDs`: one this phone forgot keeps pushing until its
    /// registration is cleaned up, and stays generic meanwhile.
    public static func alert(userInfo: [AnyHashable: Any], key: LeoPushKey, pairedDaemonIDs: Set<String>) -> LeoPushAlert? {
        guard let ciphertext = userInfo[ciphertextKey] as? String,
              let payload = try? LeoPushCipher.open(ciphertext, key: key),
              pairedDaemonIDs.contains(payload.daemonID), !payload.agent.isEmpty else { return nil }
        let hasDetail = !payload.body.isEmpty
        return LeoPushAlert(
            title: payload.agent,
            subtitle: hasDetail ? payload.title : "",
            body: hasDetail ? payload.body : payload.title,
            target: LeoPushTarget(daemonID: payload.daemonID, agent: payload.agent)
        )
    }

    /// The agent a tapped notification opens; nil for one the extension
    /// could not decrypt.
    public static func target(userInfo: [AnyHashable: Any]) -> LeoPushTarget? {
        guard let daemonID = userInfo[daemonIDKey] as? String, !daemonID.isEmpty,
              let agent = userInfo[agentKey] as? String, !agent.isEmpty else { return nil }
        return LeoPushTarget(daemonID: daemonID, agent: agent)
    }
}
