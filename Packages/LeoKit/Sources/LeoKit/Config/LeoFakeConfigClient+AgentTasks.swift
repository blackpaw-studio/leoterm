import Foundation

extension LeoFakeConfigClient: LeoAgentTaskAPI {
    public func dismissAgentTask(agent: String, id: String) async throws {
        calls.append(.dismissAgentTask(agent: agent, id: id))
        if let failure = takeWriteFailure() { throw failure }
    }
}
