import Testing
import Foundation
@testable import Ghostty

struct LeoSSEParserTests {
    @Test func parsesSingleEventInOneChunk() {
        var parser = SSEParser()
        let events = parser.feed(Data("event: hello\ndata: {\"seq\":1}\n\n".utf8))
        #expect(events == [SSEEvent(name: "hello", data: "{\"seq\":1}", id: nil)])
    }

    @Test func parsesIdField() {
        var parser = SSEParser()
        let events = parser.feed(Data("id: 42\nevent: agent_activity\ndata: {}\n\n".utf8))
        #expect(events == [SSEEvent(name: "agent_activity", data: "{}", id: "42")])
    }

    @Test func handlesChunkBoundaryMidLine() {
        var parser = SSEParser()
        var events = parser.feed(Data("event: hel".utf8))
        #expect(events.isEmpty)
        events = parser.feed(Data("lo\ndata: {}\n\n".utf8))
        #expect(events == [SSEEvent(name: "hello", data: "{}", id: nil)])
    }

    @Test func handlesChunkBoundaryMidField() {
        var parser = SSEParser()
        var events = parser.feed(Data("event: hello\ndata: {\"a\":".utf8))
        #expect(events.isEmpty)
        events = parser.feed(Data("1}\n\n".utf8))
        #expect(events == [SSEEvent(name: "hello", data: "{\"a\":1}", id: nil)])
    }

    @Test func handlesChunkBoundaryAtBlankLine() {
        var parser = SSEParser()
        var events = parser.feed(Data("event: hello\ndata: {}\n".utf8))
        #expect(events.isEmpty)
        events = parser.feed(Data("\n".utf8))
        #expect(events == [SSEEvent(name: "hello", data: "{}", id: nil)])
    }

    @Test func ignoresCommentHeartbeatLines() {
        var parser = SSEParser()
        let events = parser.feed(Data(": keepalive\nevent: hello\ndata: {}\n\n".utf8))
        #expect(events == [SSEEvent(name: "hello", data: "{}", id: nil)])
    }

    @Test func bareHeartbeatProducesNoEvent() {
        var parser = SSEParser()
        let events = parser.feed(Data(": keepalive\n\n".utf8))
        #expect(events.isEmpty)
    }

    @Test func joinsMultiLineDataWithNewline() {
        var parser = SSEParser()
        let events = parser.feed(Data("event: hello\ndata: line1\ndata: line2\n\n".utf8))
        #expect(events == [SSEEvent(name: "hello", data: "line1\nline2", id: nil)])
    }

    @Test func toleratesCRLFLineEndings() {
        var parser = SSEParser()
        let events = parser.feed(Data("event: hello\r\ndata: {}\r\n\r\n".utf8))
        #expect(events == [SSEEvent(name: "hello", data: "{}", id: nil)])
    }

    @Test func parsesMultipleEventsInOneChunk() {
        var parser = SSEParser()
        let events = parser.feed(Data(
            "event: hello\ndata: {\"seq\":1}\n\nevent: agent_activity\ndata: {\"seq\":2}\n\n".utf8
        ))
        #expect(events == [
            SSEEvent(name: "hello", data: "{\"seq\":1}", id: nil),
            SSEEvent(name: "agent_activity", data: "{\"seq\":2}", id: nil),
        ])
    }

    @Test func eventWithoutNameHasNilName() {
        var parser = SSEParser()
        let events = parser.feed(Data("data: {}\n\n".utf8))
        #expect(events == [SSEEvent(name: nil, data: "{}", id: nil)])
    }

    @Test func blankLineWithNoDataDispatchesNothing() {
        var parser = SSEParser()
        let events = parser.feed(Data("event: hello\n\n".utf8))
        #expect(events.isEmpty)
    }

    @Test func eventNameResetsAfterDispatch() {
        var parser = SSEParser()
        let events = parser.feed(Data("event: hello\ndata: a\n\ndata: b\n\n".utf8))
        #expect(events == [
            SSEEvent(name: "hello", data: "a", id: nil),
            SSEEvent(name: nil, data: "b", id: nil),
        ])
    }
}
