import Foundation
import Testing

@testable import LeoKit

struct LeoChatNotificationTests {
    typealias Actions = LeoChatNotificationActions

    static func alert(kind: String, extra: String = "") throws -> LeoPushAlert {
        let key = LeoPushKey.generate()
        let plaintext = #"{"v":1,"daemon_id":"d","agent":"zeus","kind":"\#(kind)","title":"t","body":"b","ts":1"# + extra + "}"
        let sealed = try LeoPushCipher.seal(plaintext: Data(plaintext.utf8), key: key)
        return try #require(LeoPushNotification.alert(userInfo: ["c": sealed], key: key, pairedDaemonIDs: ["d"]))
    }

    @Test func aChatPushKeepsItsMessageInTheUserInfo() throws {
        let alert = try Self.alert(kind: "chat", extra: #","message_id":"01JA""#)

        #expect(alert.chat == LeoPushChat(messageID: "01JA", messageKind: nil, options: []))
        #expect(alert.userInfo == ["daemon_id": "d", "agent": "zeus", "kind": "chat", "message_id": "01JA"])
        #expect(alert.threadIdentifier == "d/zeus")
    }

    @Test func anAttentionPushWithoutAMessageHasNoChat() throws {
        let alert = try Self.alert(kind: "needs_input")
        #expect(alert.chat == nil)
        #expect(Actions.category(for: alert) == nil)
        #expect(alert.userInfo == ["daemon_id": "d", "agent": "zeus", "kind": "needs_input"])
    }

    @Test func aPlainChatPushOffersAReply() throws {
        let category = try #require(Actions.category(for: try Self.alert(kind: "chat", extra: #","message_id":"01JA""#)))
        #expect(category.identifier == Actions.chatCategoryID)
        #expect(category.actions == [.textInput(id: Actions.replyActionID, title: "Reply", buttonTitle: "Send", placeholder: "Message")])
    }

    @Test func anAttentionPushCarryingAMessageIsAPermissionPrompt() throws {
        let category = try #require(Actions.category(for: try Self.alert(kind: "needs_input", extra: #","message_id":"01JP""#)))
        #expect(category.identifier == Actions.permissionCategoryID)
        #expect(category.actions == [
            .button(id: Actions.answerPrefix + "allow", title: "Allow", isDestructive: false),
            .button(id: Actions.answerPrefix + "deny", title: "Deny", isDestructive: true),
        ])
    }

    @Test func anAskOffersItsFirstFourOptionsAndAReply() throws {
        let options = (1...5).map { #"{"value":"v\#($0)","label":"Option \#($0)"}"# }.joined(separator: ",")
        let alert = try Self.alert(kind: "chat", extra: #","message_id":"01JQ","message_kind":"ask","options":[\#(options)]"#)
        let category = try #require(Actions.category(for: alert))

        #expect(category.identifier.hasPrefix(Actions.askCategoryPrefix))
        #expect(category.actions.count == 5)
        let buttons: [LeoChatNotificationCategory.Action] = (1...4).map {
            .button(id: Actions.answerPrefix + "v\($0)", title: "Option \($0)", isDestructive: false)
        }
        #expect(Array(category.actions.prefix(4)) == buttons)
        #expect(category.actions.last?.id == Actions.replyActionID)
        // The same options give the same category; others give another.
        #expect(Actions.category(for: alert)?.identifier == category.identifier)
        let other = try Self.alert(kind: "chat", extra: #","message_id":"01JR","message_kind":"ask","options":[{"value":"x","label":"X"}]"#)
        #expect(Actions.category(for: other)?.identifier != category.identifier)
    }

    @Test func anAskWithoutOptionsFallsBackToAReply() throws {
        let alert = try Self.alert(kind: "chat", extra: #","message_id":"01JQ","message_kind":"ask""#)
        #expect(Actions.category(for: alert)?.identifier == Actions.chatCategoryID)
    }

    @Test func theStaticCategoriesAreChatAndPermission() {
        #expect(Actions.staticCategories.map(\.identifier) == [Actions.chatCategoryID, Actions.permissionCategoryID])
    }

    @Test func aReplyActionBecomesAReplyToTheMessage() throws {
        let userInfo: [AnyHashable: Any] = ["daemon_id": "d", "agent": "zeus", "kind": "chat", "message_id": "01JA"]
        let response = Actions.response(actionIdentifier: Actions.replyActionID, userText: "  on it ", userInfo: userInfo)
        #expect(response == .reply(LeoPushTarget(daemonID: "d", agent: "zeus"), text: "on it", replyTo: "01JA"))
    }

    @Test func anEmptyReplyIsIgnored() {
        let userInfo: [AnyHashable: Any] = ["daemon_id": "d", "agent": "zeus"]
        #expect(Actions.response(actionIdentifier: Actions.replyActionID, userText: " \n", userInfo: userInfo) == nil)
    }

    @Test func anAnswerActionAnswersTheMessage() {
        let userInfo: [AnyHashable: Any] = ["daemon_id": "d", "agent": "zeus", "message_id": "01JP"]
        let response = Actions.response(actionIdentifier: Actions.answerPrefix + "deny", userText: nil, userInfo: userInfo)
        #expect(response == .answer(LeoPushTarget(daemonID: "d", agent: "zeus"), messageID: "01JP", value: "deny"))
    }

    @Test func anAnswerWithoutAMessageOrTargetIsIgnored() {
        #expect(Actions.response(actionIdentifier: Actions.answerPrefix + "allow", userText: nil, userInfo: ["daemon_id": "d", "agent": "zeus"]) == nil)
        #expect(Actions.response(actionIdentifier: Actions.answerPrefix + "allow", userText: nil, userInfo: ["message_id": "m"]) == nil)
        #expect(Actions.response(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", userText: nil, userInfo: ["daemon_id": "d", "agent": "zeus"]) == nil)
    }

    @Test func aChatPushIsAboutTheThread() {
        #expect(LeoPushNotification.isChat(userInfo: ["kind": "chat"]))
        #expect(LeoPushNotification.isChat(userInfo: ["kind": "needs_input", "message_id": "m"]))
        #expect(!LeoPushNotification.isChat(userInfo: ["kind": "needs_input"]))
    }
}
