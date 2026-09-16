import Foundation
import Testing

@testable import Ghostty

struct LeoObserveTests {
    @Test func parsesSSETranscript() throws {
        var parser = LeoSSEParser()
        let data = try fixture("events.sse")
        let events = parser.feed(data)
        #expect(events.contains(where: { $0.name == "hello" }))
        #expect(events.contains(where: { $0.name == "agent_activity" }))
    }

    @Test func absentWebBlockIsDisabled() {
        #expect(LeoObserveConfigLoader.parseWeb("agent: claude") == nil)
        let config = LeoObserveConfigLoader.parseWeb("web:\n  enabled: true\n  port: 9000\n  bind: 0.0.0.0")
        #expect(config?.enabled == true)
        #expect(config?.port == 9000)
        #expect(config?.bind == "0.0.0.0")
    }

    @Test func streamReportsSequenceGaps() async {
        let transport = EventTransport()
        let config = LeoObserveConfig(baseURL: URL(string: "http://127.0.0.1:8370")!, token: "token")
        let client = LeoActivityClient(config: config, transport: transport, initialBackoff: 1, maximumBackoff: 1)
        let stream = await client.events()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let gap = await iterator.next()
        #expect(gap == .gap(expected: 2, received: 3))
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)"))
    }
}

private struct EventTransport: LeoActivityTransport {
    func fetch(_ request: URLRequest) async throws -> (Data, Int) { (Data(), 200) }
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data("event: hello\ndata: {\"seq\":1}\n\nevent: agent_activity\ndata: {\"seq\":3,\"agent\":\"a\",\"activity\":\"working\"}\n\n".utf8))
            continuation.finish()
        }
    }
}
