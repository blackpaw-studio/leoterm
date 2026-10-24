import Foundation
import Testing

@testable import LeoKit

struct LeoRestartWaitTests {
    private struct Unreachable: Error {}

    private static let start = Date(timeIntervalSince1970: 1_000_000)

    private static func status(pid: Int, startedAt: Date? = nil) -> LeoServiceStatus {
        LeoServiceStatus(version: "0.59.0", pid: pid, startedAt: startedAt)
    }

    private static func wait(previous: LeoServiceStatus? = status(pid: 10), polls: Int = 60, deadline: TimeInterval = 720) -> LeoRestartWait {
        LeoRestartWait(previous: previous, startedAt: start, deadline: deadline, maxUnreachablePolls: polls)
    }

    @Test func samePidPollsWaitOnAgentsWithoutSpendingBudget() {
        var wait = Self.wait(polls: 2)

        for second in 1...10 {
            let step = wait.record(.success(Self.status(pid: 10)))
            #expect(step == .waiting(onAgents: true), "poll \(second)")
        }
        // The budget is all still there for the daemon going down.
        let step1 = wait.record(.failure(Unreachable()))
        #expect(step1 == .waiting(onAgents: false))
        let step2 = wait.record(.failure(Unreachable()))
        #expect(step2 == .gaveUp(afterDown: true))
    }

    @Test func newPidRestarts() {
        var wait = Self.wait()
        let fresh = Self.status(pid: 11)

        let step3 = wait.record(.failure(Unreachable()))
        #expect(step3 == .waiting(onAgents: false))
        let step4 = wait.record(.success(fresh))
        #expect(step4 == .restarted(fresh))
    }

    @Test func aNewStartTimeWithTheSamePidRestarts() {
        var wait = Self.wait(previous: Self.status(pid: 10, startedAt: Self.start))
        let fresh = Self.status(pid: 10, startedAt: Self.start.addingTimeInterval(30))

        let step5 = wait.record(.success(fresh))
        #expect(step5 == .restarted(fresh))
    }

    @Test func downThenUpWithoutPreviousRestarts() {
        var wait = Self.wait(previous: nil)
        let back = Self.status(pid: 10)

        let step6 = wait.record(.success(back))
        #expect(step6 == .waiting(onAgents: true))
        let step7 = wait.record(.failure(Unreachable()))
        #expect(step7 == .waiting(onAgents: false))
        let step8 = wait.record(.success(back))
        #expect(step8 == .restarted(back))
    }

    @Test func deadlineNeverDownGivesAgentsMessage() {
        var wait = Self.wait(deadline: 720)

        let step9 = wait.record(.success(Self.status(pid: 10)))
        #expect(step9 == .waiting(onAgents: true))
        #expect(wait.expiry(at: Self.start.addingTimeInterval(719)) == nil)
        #expect(wait.expiry(at: Self.start.addingTimeInterval(720)) == .gaveUp(afterDown: false))
    }

    @Test func deadlineAfterTheDaemonWentDownBlamesTheConnection() {
        var wait = Self.wait()

        _ = wait.record(.failure(Unreachable()))

        #expect(wait.expiry(at: Self.start.addingTimeInterval(900)) == .gaveUp(afterDown: true))
    }

    @Test func unreachableLimitGivesUp() {
        var wait = Self.wait(polls: 3)

        let step10 = wait.record(.failure(Unreachable()))
        #expect(step10 == .waiting(onAgents: false))
        let step11 = wait.record(.failure(Unreachable()))
        #expect(step11 == .waiting(onAgents: false))
        let step12 = wait.record(.failure(Unreachable()))
        #expect(step12 == .gaveUp(afterDown: true))
    }

    @Test func theMessagesNameTheMachine() {
        #expect(LeoServiceText.gaveUp(afterDown: true, machine: "Dionysus").contains("Dionysus"))
        #expect(LeoServiceText.gaveUp(afterDown: false, machine: "Dionysus").contains("Dionysus"))
        #expect(LeoServiceText.gaveUp(afterDown: true, machine: "Dionysus") != LeoServiceText.gaveUp(afterDown: false, machine: "Dionysus"))
    }

    @Test func agentsRestartMessageCountsTheRunningAgents() {
        #expect(LeoServiceText.agentsRestartMessage(running: nil) == "Every running agent will restart and lose the current turn.")
        #expect(LeoServiceText.agentsRestartMessage(running: 1) == "1 running agent will restart and lose the current turn.")
        #expect(LeoServiceText.agentsRestartMessage(running: 3) == "3 running agents will restart and lose the current turn.")
    }

    @Test func summaryNamesWhatSkippedAndFailed() {
        let result = LeoAgentsRestartResult(restarted: ["a", "b"], skipped: ["c"], failed: ["z": "boom", "y": "bang"])

        #expect(LeoServiceText.summary(of: result) == "Restarted 2 agents. 1 skipped. Couldn’t restart y: bang, z: boom.")
        #expect(LeoServiceText.failureText(of: LeoAgentsRestartResult(restarted: ["a"])) == nil)
    }
}
