import Foundation
import Testing

@testable import LeoKit

struct LeoAgentMoveTests {
    private func json(_ request: LeoMoveRequest) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        return try #require(object as? [String: Any])
    }

    private func job(_ json: String) throws -> LeoMoveJob {
        try JSONDecoder().decode(LeoMoveJob.self, from: Data(json.utf8))
    }

    @Test func moveSendsModeToAndForceOnlyWhenSet() throws {
        let plain = try json(.move(to: "nas"))
        #expect(plain as NSDictionary == ["mode": "move", "to": "nas"] as NSDictionary)
        let forced = try json(.move(to: "nas", force: true))
        #expect(forced as NSDictionary == ["mode": "move", "to": "nas", "force": true] as NSDictionary)
    }

    @Test func copySendsOptionalName() throws {
        #expect(try json(.copy(to: "nas", name: nil)) as NSDictionary == ["mode": "copy", "to": "nas"] as NSDictionary)
        #expect(try json(.copy(to: "nas", name: "fork")) as NSDictionary == ["mode": "copy", "to": "nas", "name": "fork"] as NSDictionary)
    }

    @Test func duplicateIsACopyWithNoDestination() throws {
        #expect(try json(.duplicate(name: nil)) as NSDictionary == ["mode": "copy"] as NSDictionary)
        #expect(try json(.duplicate(name: "twin")) as NSDictionary == ["mode": "copy", "name": "twin"] as NSDictionary)
    }

    @Test func blankNameIsLeftOut() throws {
        #expect(try json(.duplicate(name: "  ")) as NSDictionary == ["mode": "copy"] as NSDictionary)
    }

    @Test func decodesARunningJob() throws {
        let job = try job(#"""
        {"id":"mv-0123456789abcdef","request":{"mode":"move","to":"nas"},"state":"running",
         "stages":[{"name":"preflight","at":"2026-10-28T14:00:00Z"}],"started_at":"2026-10-28T14:00:00Z"}
        """#)
        #expect(job.id == "mv-0123456789abcdef")
        #expect(job.state == .running)
        #expect(job.request == .move(to: "nas"))
        #expect(job.error == nil)
        #expect(job.problems.isEmpty)
        #expect(job.result == nil)
    }

    @Test func decodesAFailedJobWithProblems() throws {
        let job = try job(#"""
        {"id":"mv-1","request":{"mode":"copy","name":"x"},"state":"failed",
         "error":{"code":"name_taken","message":"name_taken: x exists; no_repo: no repo"},
         "problems":[{"code":"name_taken","message":"x exists"},{"code":"no_repo","message":"no repo"}],
         "finished_at":"2026-10-28T14:00:01Z","future_key":1}
        """#)
        #expect(job.state == .failed)
        #expect(job.error?.code == "name_taken")
        #expect(job.problems.map(\.code) == ["name_taken", "no_repo"])
    }

    @Test func decodesADoneJobResult() throws {
        let job = try job(#"""
        {"id":"mv-2","request":{"mode":"copy","to":"nas"},"state":"done",
         "result":{"name":"a-copy","host":"local","to":"nas","workspace":"/w","branch":"main-a-copy","rsync":{"files":3}}}
        """#)
        #expect(job.result?.name == "a-copy")
        #expect(job.result?.to == "nas")
    }

    @Test func anUnknownStateIsNotRunning() throws {
        let job = try job(#"{"id":"mv-3","request":{"mode":"move"},"state":"paused"}"#)
        #expect(job.state == .unknown("paused"))
    }

    @Test func forceIsOfferedOnlyForABusyMove() throws {
        func failed(_ mode: String, code: String, state: String = "failed") throws -> LeoMoveJob {
            try job(#"{"id":"m","request":{"mode":"\#(mode)"},"state":"\#(state)","error":{"code":"\#(code)","message":"busy"}}"#)
        }
        #expect(try failed("move", code: "agent_busy").offersForce)
        #expect(try !failed("copy", code: "agent_busy").offersForce)
        #expect(try !failed("move", code: "name_taken").offersForce)
        #expect(try !failed("move", code: "agent_busy", state: "running").offersForce)
    }
}
