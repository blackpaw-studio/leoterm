import Foundation
import Testing

@testable import LeoKit

struct LeoPluginWireTests {
    @Test func hostToAppCapMatchesTheFrameLimit() {
        #expect(LeoPluginWire.maxHostToAppBytes == LeoPluginFrameLimits.maxFrameBytes)
    }

    @Test func encodePrefixesABigEndianLength() throws {
        let framed = try LeoPluginWire.encode(Data("hi!".utf8), limit: 100)
        #expect(Array(framed) == [0, 0, 0, 3, 0x68, 0x69, 0x21])
    }

    @Test func encodeRefusesAPayloadOverTheLimit() {
        #expect(throws: LeoPluginWireError.tooLarge(bytes: 11, limit: 10)) {
            try LeoPluginWire.encode(Data(count: 11), limit: 10)
        }
    }

    @Test func readerReassemblesAFrameSplitAcrossChunks() throws {
        var reader = LeoPluginFrameReader(limit: 100)
        let framed = try LeoPluginWire.encode(Data("hello".utf8), limit: 100)
        var frames: [Data] = []
        for byte in framed { frames += try reader.append(Data([byte])) }
        #expect(frames == [Data("hello".utf8)])
    }

    @Test func readerReturnsEveryFrameInOneChunk() throws {
        var reader = LeoPluginFrameReader(limit: 100)
        let chunk = try LeoPluginWire.encode(Data("a".utf8), limit: 100)
            + LeoPluginWire.encode(Data("bc".utf8), limit: 100)
            + LeoPluginWire.encode(Data(), limit: 100)
        #expect(try reader.append(chunk) == [Data("a".utf8), Data("bc".utf8), Data()])
    }

    @Test func readerRejectsAnOversizedHeaderBeforeBufferingTheBody() {
        var reader = LeoPluginFrameReader(limit: 10)
        // Declares 4 GiB - 1 and sends only the header.
        #expect(throws: LeoPluginWireError.tooLarge(bytes: Int(UInt32.max), limit: 10)) {
            try reader.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        }
    }

    @Test func readerStaysFailedAfterAnError() {
        var reader = LeoPluginFrameReader(limit: 10)
        _ = try? reader.append(Data([0, 0, 0, 11]))
        #expect(throws: LeoPluginWireError.self) { try reader.append(Data([0, 0, 0, 1, 0x41])) }
    }

    @Test func hostMessageDecodesARequestAndTheDoneMarker() throws {
        let request = LeoPluginHostRequest.log(level: "info", message: "x")
        let json = try JSONEncoder().encode(request)
        #expect(try LeoPluginHostMessage.decode(frame: json) == .request(request))
        #expect(try LeoPluginHostMessage.decode(frame: LeoPluginWire.doneFrame) == .handlerDone)
    }

    @Test func hostMessageRejectsOversizedAndNonUTF8Frames() {
        #expect(throws: LeoPluginFrameError.self) {
            try LeoPluginHostMessage.decode(frame: Data(count: LeoPluginFrameLimits.maxFrameBytes + 1))
        }
        #expect(throws: LeoPluginWireError.notUTF8) {
            try LeoPluginHostMessage.decode(frame: Data([0xFF, 0xFE]))
        }
    }

    @Test func commandsRoundTrip() throws {
        let commands: [LeoPluginHostCommand] = [.load(source: "leo.log('a','b')"), .deliver(.agentsChanged)]
        for command in commands {
            let data = try JSONEncoder().encode(command)
            #expect(try JSONDecoder().decode(LeoPluginHostCommand.self, from: data) == command)
        }
    }

    @Test func aPaneSlotRoundTripsWithItsWireShape() throws {
        let ref = LeoPluginAgentRef(machine: "localhost", name: "alpha")
        let slot = LeoPluginSlotID.pane(id: "status", part: .summary, agent: ref)
        let data = try JSONEncoder().encode(slot)
        #expect(try JSONDecoder().decode(LeoPluginSlotID.self, from: data) == slot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["kind"] as? String == "pane")
        #expect(object["id"] as? String == "status")
        #expect(object["part"] as? String == "summary")
        #expect(slot.key == "pane:status:summary:localhost:alpha")
        #expect(slot != .pane(id: "status", part: .body, agent: ref))
        #expect(slot.key != LeoPluginSlotID.pane(id: "status", part: .body, agent: ref).key)
    }

    @Test func aPaneSlotWithAnUnknownPartIsRefused() {
        let json = #"{"kind":"pane","id":"status","part":"footer","agent":{"machine":"m","name":"a"}}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LeoPluginSlotID.self, from: Data(json.utf8)) }
    }
}
