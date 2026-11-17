import Foundation
import LeoKit

/// A scriptable client-tools daemon: each `events()` is a new stream the
/// test feeds; routes record their calls.
@MainActor final class FakeClientTools: LeoClientToolsProviding {
    private(set) var streams: [AsyncStream<LeoClientToolsEvent>.Continuation] = []
    private(set) var endedStreams = 0
    private(set) var registered: [(group: String, tools: [LeoClientToolDefinition])] = []
    private(set) var claims: [String] = []
    private(set) var results: [(id: String, outcome: LeoClientToolOutcome)] = []
    var claimErrors: [String: any Error] = [:]
    var pendingRequests: [LeoClientToolPending] = []

    @MainActor func events() async -> AsyncStream<LeoClientToolsEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: LeoClientToolsEvent.self)
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.endedStreams += 1 } }
        streams.append(continuation)
        return stream
    }

    @MainActor func register(group: String, tools: [LeoClientToolDefinition]) async throws -> Int {
        registered.append((group, tools))
        return registered.count
    }

    @MainActor func claim(_ requestID: String) async throws -> LeoClientToolRequest {
        claims.append(requestID)
        if let error = claimErrors[requestID] { throw error }
        guard let request = pendingRequests.first(where: { $0.request.id == requestID })?.request else {
            throw LeoClientToolsError.unknownRequest(message: "unknown")
        }
        return request
    }

    /// Posts that fail with a transient error before one lands.
    var failingPosts = 0
    private(set) var postAttempts = 0

    @MainActor func postResult(_ requestID: String, _ outcome: LeoClientToolOutcome) async throws {
        postAttempts += 1
        if failingPosts > 0 {
            failingPosts -= 1
            throw LeoClientToolsError.other(code: nil, message: "connection reset")
        }
        results.append((requestID, outcome))
    }

    @MainActor func pending() async throws -> [LeoClientToolPending] { pendingRequests }

    /// Sends `event` on the newest stream.
    func send(_ event: LeoClientToolsEvent) { streams.last?.yield(event) }

    /// The newest stream ends, as when the daemon drops it.
    func drop(reason: String = "closed") {
        streams.last?.yield(.disconnected(reason: reason))
        streams.last?.finish()
    }
}
