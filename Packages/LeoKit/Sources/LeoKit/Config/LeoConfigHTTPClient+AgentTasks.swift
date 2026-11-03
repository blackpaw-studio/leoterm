import Foundation

extension LeoConfigHTTPClient: LeoAgentTaskAPI {
    public func dismissAgentTask(agent: String, id: String) async throws {
        let path = "\(prefix)/agents/\(try Self.segment(agent, what: "Agent name"))/\(LeoAgentTaskWire.dismissAction)/\(try Self.segment(id, what: "Task id"))"
        try await delete(path)
    }
}
