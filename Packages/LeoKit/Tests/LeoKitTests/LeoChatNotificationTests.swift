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

        #expect(alert.chat == LeoPushChat(messageID: "01JA", messageKind: nil, options: [], inputType: nil))
        #expect(alert.userInfo == ["daemon_id": "d", "agent": "zeus", "kind": "chat", "message_id": "01JA"])
        let ask = try Self.alert(kind: "chat", extra: #","message_id":"01JQ","message_kind":"ask""#)
        #expect(ask.userInfo["message_kind"] == "ask")
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

    @Test func anAskOffersItsFirstFourOptionsAndNoReply() throws {
        let options = (1...5).map { #"{"value":"v\#($0)","label":"Option \#($0)"}"# }.joined(separator: ",")
        let alert = try Self.alert(kind: "chat", extra: #","message_id":"01JQ","message_kind":"ask","options":[\#(options)]"#)
        let category = try #require(Actions.category(for: alert))

        #expect(category.identifier.hasPrefix(Actions.askCategoryPrefix))
        let buttons: [LeoChatNotificationCategory.Action] = (1...4).map {
            .button(id: Actions.answerPrefix + "v\($0)", title: "Option \($0)", isDestructive: false)
        }
        #expect(category.actions == buttons)
        // The same options give the same category; others give another.
        #expect(Actions.category(for: alert)?.identifier == category.identifier)
        let other = try Self.alert(kind: "chat", extra: #","message_id":"01JR","message_kind":"ask","options":[{"value":"x","label":"X"}]"#)
        #expect(Actions.category(for: other)?.identifier != category.identifier)
    }

    static let yesNo = #","options":[{"value":"y","label":"Yes"},{"value":"n","label":"No"}]"#

    @Test func aButtonsAskOffersItsButtons() throws {
        let alert = try Self.alert(kind: "chat", extra: #","message_id":"01JQ","message_kind":"ask","input_type":"buttons""# + Self.yesNo)
        let category = try #require(Actions.category(for: alert))
        #expect(category.identifier.hasPrefix(Actions.askCategoryPrefix))
        #expect(category.actions.map(\.id) == [Actions.answerPrefix + "y", Actions.answerPrefix + "n"])
    }

    /// An older daemon sends options without `input_type`: still buttons.
    @Test func anAskWithOptionsButNoInputTypeOffersButtons() throws {
        let alert = try Self.alert(kind: "chat", extra: #","message_id":"01JQ","message_kind":"ask""# + Self.yesNo)
        let category = try #require(Actions.category(for: alert))
        #expect(category.identifier.hasPrefix(Actions.askCategoryPrefix))
        #expect(category.actions.map(\.id) == [Actions.answerPrefix + "y", Actions.answerPrefix + "n"])
    }

    /// The extension registers categories by the per-choice prefix; the
    /// static open-ask category must not match it.
    @Test func theOpenAskCategoryIsNotAPerChoiceCategory() {
        #expect(!Actions.askOpenCategoryID.hasPrefix(Actions.askCategoryPrefix))
    }

    /// No buttons and no reply: a reply would look like an answer.
    @Test func anAskWithoutOptionsOpensTheApp() throws {
        let alert = try Self.alert(kind: "chat", extra: #","message_id":"01JQ","message_kind":"ask""#)
        let category = try #require(Actions.category(for: alert))
        #expect(category.identifier == Actions.askOpenCategoryID)
        #expect(category.actions.isEmpty)
    }

    @Test(arguments: ["radio", "checkboxes", "text", "slider"])
    func anAskThatIsNotButtonsOpensTheApp(inputType: String) throws {
        let extra = #","message_id":"01JQ","message_kind":"ask","input_type":"\#(inputType)""# + Self.yesNo
        let category = try #require(Actions.category(for: try Self.alert(kind: "chat", extra: extra)))
        #expect(category == LeoChatNotificationCategory(identifier: Actions.askOpenCategoryID, actions: []))
    }

    @Test func malformedOptionsMeanNoButtons() throws {
        let alert = try Self.alert(kind: "chat", extra: #","message_id":"01JQ","message_kind":"ask","input_type":"buttons","options":"yes""#)
        #expect(Actions.category(for: alert)?.identifier == Actions.askOpenCategoryID)
    }

    @Test func theStaticCategoriesAreChatPermissionAndOpenAsk() {
        #expect(Actions.staticCategories.map(\.identifier) == [Actions.chatCategoryID, Actions.permissionCategoryID, Actions.askOpenCategoryID])
    }

    @Test func aReplyActionBecomesAReplyToTheMessage() throws {
        let userInfo: [AnyHashable: Any] = ["daemon_id": "d", "agent": "zeus", "kind": "chat", "message_id": "01JA"]
        let response = Actions.response(actionIdentifier: Actions.replyActionID, userText: "  on it ", userInfo: userInfo)
        #expect(response == .reply(LeoPushTarget(daemonID: "d", agent: "zeus"), text: "on it", replyTo: "01JA"))
    }

    /// Text typed into a Reply on a prompt's notification (a category
    /// registered by an older build) would post a message that never
    /// answers it: open the thread instead.
    @Test(arguments: [
        ["kind": "chat", "message_kind": "ask"],
        ["kind": "chat", "message_kind": "permission"],
        ["kind": "needs_input", "message_kind": "permission"],
        ["kind": "needs_input"],
    ] as [[String: String]])
    func aReplyToAPromptOpensTheThreadInstead(extra: [String: String]) {
        let userInfo: [AnyHashable: Any] = extra.merging(["daemon_id": "d", "agent": "zeus", "message_id": "01JQ"]) { $1 }
        #expect(Actions.response(actionIdentifier: Actions.replyActionID, userText: "yes please", userInfo: userInfo) == nil)
        #expect(Actions.opensThread(actionIdentifier: Actions.replyActionID, userInfo: userInfo))
    }

    @Test func onlyTheDefaultActionOrAStalePromptReplyOpensTheThread() {
        let chat: [AnyHashable: Any] = ["daemon_id": "d", "agent": "zeus", "kind": "chat", "message_id": "01JA"]
        #expect(Actions.opensThread(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: chat))
        #expect(!Actions.opensThread(actionIdentifier: Actions.replyActionID, userInfo: chat))
        #expect(!Actions.opensThread(actionIdentifier: "com.apple.UNNotificationDismissActionIdentifier", userInfo: chat))
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
