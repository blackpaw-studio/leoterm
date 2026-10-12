import Foundation
import Testing

@testable import LeoKit

struct LeoChatDecodingTests {
    static let askJSON = #"""
    {"id":"01JA","agent":"zeus","direction":"out","kind":"ask","text":"Deploy now?","state":"open",
     "ts":"2026-10-12T18:00:00Z","options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]}
    """#

    @Test func decodesAnAskWithItsOptions() throws {
        let message = try JSONDecoder().decode(LeoChatMessage.self, from: Data(Self.askJSON.utf8))

        #expect(message.id == "01JA")
        #expect(message.agent == "zeus")
        #expect(message.direction == .outbound)
        #expect(message.kind == .ask)
        #expect(message.text == "Deploy now?")
        #expect(message.isOpen)
        #expect(message.options == [LeoChatOption(value: "yes", label: "Yes"), LeoChatOption(value: "no", label: "No")])
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
        let json = #"{"ok":true,"data":[{"agent":"assistant","pinned":true,"unread":3,"last_message":\#(Self.askJSON)},{"agent":"zeus","unread_count":1}]}"#
        let threads = try LeoDaemonEnvelope<[LeoChatThread]>.decode(Data(json.utf8)).value()

        #expect(threads.map(\.agent) == ["assistant", "zeus"])
        #expect(threads[0].isPinned)
        #expect(threads[0].unread == 3)
        #expect(threads[0].lastMessage?.id == "01JA")
        #expect(threads[1].unread == 1)
        #expect(!threads[1].isPinned)
        #expect(threads[1].lastMessage == nil)
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
}
