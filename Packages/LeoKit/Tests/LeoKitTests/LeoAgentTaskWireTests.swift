import Foundation
import Testing

@testable import LeoKit

struct LeoAgentTaskWireTests {
    private func decode(_ json: String) throws -> LeoObservedAgent {
        try JSONDecoder().decode(LeoObservedAgent.self, from: Data(json.utf8))
    }

    private func event(_ name: String) throws -> LeoObserveEvent? {
        let data = try LeoAppearanceWireTests.fixture(name)
        return LeoActivityClient.decode(LeoSSEEvent(name: "agent_task_changed", data: String(bytes: data, encoding: .utf8) ?? "", id: nil))
    }

    @Test func decodesFullTask() throws {
        let data = try LeoAppearanceWireTests.fixture("agent-task")
        let task = try JSONDecoder().decode(LeoAgentTask.self, from: data)
        #expect(task.id == "build")
        #expect(task.title == "Xcode build")
        #expect(task.mode == .determinate)
        #expect(task.percent == 62)
        #expect(task.status == "Compiling 412/980")
        #expect(task.state == .running)
        #expect(!task.stale)
        #expect(task.revision == 7)
        #expect(task.etaAt == Date(timeIntervalSince1970: 1_793_734_800))
        #expect(task.startedAt == Date(timeIntervalSince1970: 1_793_733_600))
        #expect(task.updatedAt.timeIntervalSince1970 == 1_793_734_200.25)
        #expect(task.endedAt == nil)
    }

    @Test func unknownModeAndStateDegrade() throws {
        let agent = try decode(#"{"name":"a","tasks":[{"id":"x","title":"T","mode":"spiral","state":"paused","percent":10,"revision":1}]}"#)
        #expect(agent.tasks.first?.mode == .determinate)
        #expect(agent.tasks.first?.state == .running)
        let bare = try decode(#"{"name":"a","tasks":[{"id":"y","title":"T","mode":"spiral","revision":1}]}"#)
        #expect(bare.tasks.first?.mode == .indeterminate)
    }

    @Test func missingTasksIsEmpty() throws {
        #expect(try decode(#"{"name":"a"}"#).tasks.isEmpty)
        #expect(try decode(#"{"name":"a","tasks":"junk"}"#).tasks.isEmpty)
    }

    @Test func malformedTaskIsDroppedOthersSurvive() throws {
        let agent = try decode(#"{"name":"a","tasks":[{"title":"no id"},{"id":"ok","title":"Fine","revision":2}]}"#)
        #expect(agent.tasks.map(\.id) == ["ok"])
    }

    @Test func percentIsClamped() throws {
        let agent = try decode(#"{"name":"a","tasks":[{"id":"x","title":"T","percent":140,"revision":1}]}"#)
        #expect(agent.tasks.first?.percent == 100)
    }

    @Test func decodesTaskEvent() throws {
        guard case .agentTaskChanged(let seq, _, let agent, let id, let task)? = try event("agent-task-event") else {
            Issue.record("wrong event"); return
        }
        #expect(seq == 812)
        #expect(agent == "alfred")
        #expect(id == "build")
        #expect(task?.percent == 62)
    }

    @Test func nullTaskMeansRemoved() throws {
        guard case .agentTaskChanged(let seq, _, _, let id, let task)? = try event("agent-task-event-null") else {
            Issue.record("wrong event"); return
        }
        #expect(seq == 813)
        #expect(id == "build")
        #expect(task == nil)
    }

    @Test func malformedEventKeepsOnlySequence() {
        let sse = LeoSSEEvent(name: "agent_task_changed", data: #"{"seq":9,"task":{"id":"x"}}"#, id: nil)
        guard case .other(let seq, _)? = LeoActivityClient.decode(sse) else { Issue.record("wrong event"); return }
        #expect(seq == 9)
    }

    @Test func advertisesAgentProgress() {
        #expect(LeoDaemonFeatures(["agent_progress"]).contains(.agentProgress))
        #expect(!LeoDaemonFeatures.none.contains(.agentProgress))
    }
}
