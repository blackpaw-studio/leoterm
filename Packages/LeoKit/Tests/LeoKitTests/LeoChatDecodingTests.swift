import Foundation
import Testing

@testable import LeoKit

struct LeoChatDecodingTests {
    static let askJSON = #"""
    {"id":"01JA","agent":"zeus","direction":"out","kind":"ask","text":"Deploy now?","state":"open",
     "ts":"2026-10-12T18:00:00Z","input":{"type":"buttons","options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]}}
    """#

    static func ask(input: String) -> String {
        #"{"id":"01JA","agent":"zeus","direction":"out","kind":"ask","text":"q","state":"open","ts":0,"input":\#(input)}"#
    }

    static func decode(_ json: String) throws -> LeoChatMessage {
        try JSONDecoder().decode(LeoChatMessage.self, from: Data(json.utf8))
    }

    static let yesNo = #"[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]"#

    @Test func decodesAnAskWithItsOptions() throws {
        let message = try JSONDecoder().decode(LeoChatMessage.self, from: Data(Self.askJSON.utf8))

        #expect(message.id == "01JA")
        #expect(message.agent == "zeus")
        #expect(message.direction == .outbound)
        #expect(message.kind == .ask)
        #expect(message.text == "Deploy now?")
        #expect(message.isOpen)
        #expect(message.input?.kind == .buttons)
        #expect(message.input?.options == [LeoChatOption(value: "yes", label: "Yes"), LeoChatOption(value: "no", label: "No")])
        #expect(message.answer == nil)
        #expect(message.ts == Date(timeIntervalSince1970: 1_791_828_000))
        #expect(message.attachments.isEmpty)
    }

    @Test func decodesAVoiceNoteWithTranscriptAndAttachment() throws {
        let json = #"""
        {"id":"01JB","agent":"zeus","direction":"in","kind":"voice","text":"","transcript":"hello there","state":"delivered",
         "reply_to":"01J0","ts":"2026-10-12T18:00:00.250Z",
         "attachments":[{"id":"att1","filename":"note.m4a","mime":"audio/mp4","bytes":4096}]}
        """#
        let message = try JSONDecoder().decode(LeoChatMessage.self, from: Data(json.utf8))

        #expect(message.direction == .inbound)
        #expect(message.kind == .voice)
        #expect(message.transcript == "hello there")
        #expect(message.replyTo == "01J0")
        #expect(message.state == "delivered")
        #expect(message.attachments == [LeoChatAttachment(id: "att1", filename: "note.m4a", mime: "audio/mp4", bytes: 4096)])
        #expect(message.attachments.first?.isAudio == true)
        #expect(message.ts.timeIntervalSince1970 == 1_791_828_000.25)
    }

    @Test func decodesATaskCard() throws {
        let json = #"{"id":"01JC","agent":"assistant","direction":"out","kind":"task","text":"Wharf: crane up","task":"wharf","run_id":"r-9","ts":1791828000}"#
        let message = try JSONDecoder().decode(LeoChatMessage.self, from: Data(json.utf8))

        #expect(message.kind == .task)
        #expect(message.task == "wharf")
        #expect(message.runID == "r-9")
        #expect(message.ts == Date(timeIntervalSince1970: 1_791_828_000))
    }

    @Test func millisecondTimestampsAreRecognized() throws {
        let json = #"{"id":"x","agent":"a","direction":"out","kind":"text","text":"t","ts":1791828000500}"#
        let message = try JSONDecoder().decode(LeoChatMessage.self, from: Data(json.utf8))
        #expect(message.ts.timeIntervalSince1970 == 1_791_828_000.5)
    }

    @Test func anUnknownKindIsKeptAsUnknown() throws {
        let json = #"{"id":"x","agent":"a","direction":"out","kind":"reaction","text":"👍","ts":0}"#
        let message = try JSONDecoder().decode(LeoChatMessage.self, from: Data(json.utf8))
        #expect(message.kind == .unknown)
    }

    @Test func aPageDropsMalformedMessagesAndReadsHasMore() throws {
        let json = #"{"ok":true,"data":{"messages":[\#(Self.askJSON),{"id":"bad"}],"has_more":true}}"#
        let page = try LeoDaemonEnvelope<LeoChatPage>.decode(Data(json.utf8)).value()

        #expect(page.messages.map(\.id) == ["01JA"])
        #expect(page.hasMore)
    }

    @Test func aBareArrayIsAPage() throws {
        let json = #"{"ok":true,"data":[\#(Self.askJSON)]}"#
        let page = try LeoDaemonEnvelope<LeoChatPage>.decode(Data(json.utf8)).value()
        #expect(page.messages.count == 1)
        #expect(!page.hasMore)
    }

    @Test func decodesThreads() throws {
        let json = #"{"ok":true,"data":{"threads":[{"agent":"assistant","pinned":true,"unread":3,"last_message":\#(Self.askJSON)},{"agent":"zeus","unread_count":1},{"bad":1}]}}"#
        let threads = try LeoDaemonEnvelope<LeoChatThreadList>.decode(Data(json.utf8)).value().threads

        #expect(threads.map(\.agent) == ["assistant", "zeus"])
        #expect(threads[0].isPinned)
        #expect(threads[0].unread == 3)
        #expect(threads[0].lastMessage?.id == "01JA")
        #expect(threads[1].unread == 1)
        #expect(!threads[1].isPinned)
        #expect(threads[1].lastMessage == nil)
    }

    @Test func aBareThreadArrayAlsoDecodes() throws {
        let json = #"{"ok":true,"data":[{"agent":"zeus","unread":1}]}"#
        #expect(try LeoDaemonEnvelope<LeoChatThreadList>.decode(Data(json.utf8)).value().threads.map(\.agent) == ["zeus"])
    }

    @Test func decodesChatEventsFromTheObserveStream() throws {
        let created = LeoActivityClient.decode(LeoSSEEvent(name: "chat.message", data: #"{"seq":12,"agent":"zeus","message":\#(Self.askJSON)}"#))
        let updated = LeoActivityClient.decode(LeoSSEEvent(name: nil, data: #"{"type":"chat.updated","seq":13,"message":\#(Self.askJSON)}"#))

        let message = try JSONDecoder().decode(LeoChatMessage.self, from: Data(Self.askJSON.utf8))
        #expect(created == .chat(seq: 12, .message(message)))
        #expect(updated == .chat(seq: 13, .updated(message)))
        #expect(created?.sequence == 12)
    }

    @Test func aMalformedChatEventOnlyAdvancesTheSequence() {
        let event = LeoActivityClient.decode(LeoSSEEvent(name: "chat.message", data: #"{"seq":14,"message":{"id":"x"}}"#))
        #expect(event == .other(seq: 14, type: "chat.message"))
    }

    // MARK: Ask inputs (leo #268)

    @Test(arguments: [
        (#"{"type":"buttons","options":\#(LeoChatDecodingTests.yesNo)}"#, LeoChatInput.Kind.buttons, false, 0, 2, String?.none),
        (#"{"type":"radio","options":\#(LeoChatDecodingTests.yesNo),"allow_text":true,"placeholder":"Other"}"#, .radio, true, 0, 2, "Other"),
        (#"{"type":"checkboxes","options":\#(LeoChatDecodingTests.yesNo)}"#, .checkboxes, false, 0, 2, nil),
        (#"{"type":"checkboxes","options":\#(LeoChatDecodingTests.yesNo),"min":1,"max":1}"#, .checkboxes, false, 1, 1, nil),
        (#"{"type":"text","placeholder":"Why?"}"#, .text, false, 0, 0, "Why?"),
        (#"{"type":"text"}"#, .text, false, 0, 0, nil),
    ])
    func eachInputTypeDecodesWithItsDefaults(json: String, kind: LeoChatInput.Kind, allowsText: Bool, min: Int, max: Int, placeholder: String?) throws {
        let input = try #require(try Self.decode(Self.ask(input: json)).input)

        #expect(input.kind == kind)
        #expect(input.options.count == (kind == .text ? 0 : 2))
        #expect(input.allowsText == allowsText)
        #expect(input.min == min)
        #expect(input.max == max)
        #expect(input.placeholder == placeholder)
    }

    @Test(arguments: [
        #"{"type":"buttons","options":["yes","no"]}"#,
        #"{"type":"buttons","options":[{"value":"yes"}]}"#,
        #"{"type":"buttons","options":[{"value":1,"label":"One"}]}"#,
        #"{"type":"buttons","options":[]}"#,
        #"{"type":"buttons"}"#,
        #"{"type":"radio","options":[\#((1...13).map { #"{"value":"v\#($0)","label":"L"}"# }.joined(separator: ","))]}"#,
        #"{"type":"text","options":\#(LeoChatDecodingTests.yesNo)}"#,
        #"{"type":"text","allow_text":true}"#,
        #"{"type":"radio","options":\#(LeoChatDecodingTests.yesNo),"min":1}"#,
        #"{"type":"radio","options":\#(LeoChatDecodingTests.yesNo),"max":1}"#,
        #"{"type":"checkboxes","options":\#(LeoChatDecodingTests.yesNo),"min":2,"max":1}"#,
        #"{"type":"checkboxes","options":\#(LeoChatDecodingTests.yesNo),"max":0}"#,
        #"{"type":"checkboxes","options":\#(LeoChatDecodingTests.yesNo),"max":3}"#,
        #"{"type":"checkboxes","options":\#(LeoChatDecodingTests.yesNo),"min":-1}"#,
        #"{"type":"buttons","options":[{"value":"a","label":"A"},{"value":"a","label":"B"}]}"#,
        #"{"type":"buttons","options":[{"value":" ","label":"Blank"}]}"#,
        #"{"type":"text","placeholder":"\#(String(repeating: "é", count: 201))"}"#,
        #"{"type":"radio","options":\#(LeoChatDecodingTests.yesNo),"placeholder":"no field for it"}"#,
        #"{"type":"slider","options":\#(LeoChatDecodingTests.yesNo)}"#,
        #""buttons""#,
    ])
    func anInvalidInputFailsTheMessage(json: String) {
        #expect(throws: (any Error).self) { try Self.decode(Self.ask(input: json)) }
    }

    @Test func aTwoHundredScalarPlaceholderIsAllowed() throws {
        let placeholder = String(repeating: "é", count: 200)
        let input = try Self.decode(Self.ask(input: #"{"type":"text","placeholder":"\#(placeholder)"}"#)).input
        #expect(input?.placeholder == placeholder)
    }

    @Test func anAskWithoutAnInputFailsToDecode() {
        let json = #"{"id":"01JA","agent":"zeus","direction":"out","kind":"ask","text":"q","state":"open","ts":0}"#
        #expect(throws: (any Error).self) { try Self.decode(json) }
    }

    @Test func aPermissionRowWithoutAnInputIsAnsweredAllowOrDeny() throws {
        let json = #"{"id":"01JP","agent":"zeus","direction":"out","kind":"permission","text":"Bash: ls","state":"open","ts":0}"#
        let message = try Self.decode(json)

        #expect(message.input == nil)
        #expect(message.answerInput == .permission)
        #expect(LeoChatInput.permission.kind == .buttons)
        #expect(LeoChatInput.permission.options.map(\.value) == ["allow", "deny"])
    }

    @Test func aPermissionRowKeepsTheInputItCarries() throws {
        let json = #"{"id":"01JP","agent":"zeus","direction":"out","kind":"permission","text":"Bash: ls","state":"open","ts":0,"input":{"type":"buttons","options":[{"value":"allow","label":"Allow"},{"value":"deny","label":"Deny"}]}}"#
        let message = try Self.decode(json)
        #expect(message.answerInput?.options.map(\.label) == ["Allow", "Deny"])
    }

    @Test func plainMessagesHaveNoAnswerInput() throws {
        let json = #"{"id":"x","agent":"a","direction":"out","kind":"text","text":"t","ts":0}"#
        #expect(try Self.decode(json).answerInput == nil)
    }

    @Test func anEmptyAnswerTextDecodesAsNil() throws {
        let json = #"{"id":"01JP","agent":"zeus","direction":"out","kind":"permission","text":"Bash: ls","state":"answered","ts":0,"answer":{"values":["terminal"],"text":""}}"#
        #expect(try Self.decode(json).answer == LeoChatAnswer(values: ["terminal"], text: nil))
    }

    @Test func anAnswerKeepsItsValuesAndText() throws {
        let json = Self.ask(input: #"{"type":"checkboxes","options":\#(Self.yesNo)}"#)
            .replacingOccurrences(of: #""state":"open""#, with: #""state":"answered","answer":{"values":["no","yes"],"text":"both"}"#)
        #expect(try Self.decode(json).answer == LeoChatAnswer(values: ["no", "yes"], text: "both"))
    }

    @Test(arguments: [#""yes""#, #"{"text":"x"}"#, #"{"values":"yes","text":""}"#, #"{"values":[1],"text":""}"#])
    func aMalformedAnswerFailsTheMessage(answer: String) {
        let json = Self.ask(input: #"{"type":"buttons","options":\#(Self.yesNo)}"#)
            .replacingOccurrences(of: #""state":"open""#, with: #""state":"answered","answer":\#(answer)"#)
        #expect(throws: (any Error).self) { try Self.decode(json) }
    }

    @Test func anAnswerEncodesTextOnlyWhenItHasSome() throws {
        let bare = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LeoChatAnswer.choice("yes"))) as? [String: Any]
        let full = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LeoChatAnswer(values: [], text: "hi"))) as? [String: Any]

        #expect(bare?.keys.sorted() == ["values"])
        #expect(bare?["values"] as? [String] == ["yes"])
        #expect(full?["values"] as? [String] == [])
        #expect(full?["text"] as? String == "hi")
        #expect(LeoChatAnswer(values: ["a"], text: "").text == nil)
        #expect(LeoChatAnswer.maxTextScalars == 4000)
    }

    @Test func aMessageRoundTripsThroughItsOwnEncoding() throws {
        let json = Self.ask(input: #"{"type":"checkboxes","options":\#(Self.yesNo),"min":1,"allow_text":true,"placeholder":"Other"}"#)
            .replacingOccurrences(of: #""state":"open""#, with: #""state":"answered","answer":{"values":["no"],"text":"and"}"#)
        let message = try Self.decode(json)
        #expect(try JSONDecoder().decode(LeoChatMessage.self, from: JSONEncoder().encode(message)) == message)
    }
}
