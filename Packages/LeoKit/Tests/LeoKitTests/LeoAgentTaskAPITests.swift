import Foundation
import Testing

@testable import LeoKit

/// Dismissing a failed agent task over both transports: the socket serves
/// the route bare, the web listener under `/api/v1`. The daemon answers 204.
struct LeoAgentTaskAPITests {
    static let prefixes = ["", "/api/v1"]

    @Test(arguments: prefixes)
    func dismissesWithDelete(prefix: String) async throws {
        let transport = ConfigRecordingTransport(body: "", status: 204)
        try await LeoConfigHTTPClient(prefix: prefix, transport: transport).dismissAgentTask(agent: "alfred", id: "build")

        let request = try #require(await transport.requests.first)
        #expect(request.method == "DELETE")
        #expect(request.path == "\(prefix)/agents/alfred/tasks/build")
        #expect(request.body == nil && request.headers.isEmpty)
    }

    @Test func escapesPathSegments() async throws {
        let transport = ConfigRecordingTransport(body: "", status: 204)
        try await LeoConfigHTTPClient(prefix: "", transport: transport).dismissAgentTask(agent: "a b", id: "x.y-z")
        let request = try #require(await transport.requests.first)
        #expect(request.path == "/agents/a%20b/tasks/x.y-z")
    }

    @Test func unknownTaskIsNotFound() async throws {
        let transport = ConfigRecordingTransport(body: #"{"ok":false,"code":"not_found","error":"no task"}"#, status: 404)
        await #expect(throws: LeoAgentTaskError.notFound) {
            try await LeoConfigHTTPClient(prefix: "", transport: transport).dismissAgentTask(agent: "a", id: "x")
        }
    }

    @Test func runningTaskIsNotDismissable() async throws {
        let transport = ConfigRecordingTransport(body: #"{"ok":false,"code":"conflict","error":"task is still running"}"#, status: 409)
        await #expect(throws: LeoAgentTaskError.notDismissable(reason: "task is still running")) {
            try await LeoConfigHTTPClient(prefix: "/api/v1", transport: transport).dismissAgentTask(agent: "a", id: "x")
        }
    }

    @Test func otherFailuresStayDaemonErrors() async throws {
        let transport = ConfigRecordingTransport(body: #"{"ok":false,"code":"forbidden","error":"nope"}"#, status: 403)
        await #expect(throws: LeoDaemonError.self) {
            try await LeoConfigHTTPClient(prefix: "", transport: transport).dismissAgentTask(agent: "a", id: "x")
        }
    }

    @Test func emptyNamesAreRejectedBeforeSending() async throws {
        let transport = ConfigRecordingTransport(body: "", status: 204)
        await #expect(throws: LeoDaemonError.self) {
            try await LeoConfigHTTPClient(prefix: "", transport: transport).dismissAgentTask(agent: "", id: "x")
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func fakeRecordsTheDismissal() async throws {
        let fake = LeoFakeConfigClient(schema: try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema"))
        try await fake.dismissAgentTask(agent: "a", id: "x")
        #expect(await fake.calls.last == .dismissAgentTask(agent: "a", id: "x"))
    }
}
