import Foundation
import Testing

@testable import LeoKit

struct LeoInboxTests {
    typealias F = LeoInboxFixtures

    private func derive(
        _ agents: [LeoInboxAgent], asks: [LeoAgentID: LeoOpenAskThread] = [:], seen: LeoInboxSeenState = LeoInboxSeenState()
    ) -> LeoInbox {
        LeoInbox.derive(agents: agents, openAsks: asks, seen: seen)
    }

    @Test func anOpenChatAskIsBlockedWithItsQuestionAndContext() throws {
        let ask = F.ask("m1", agent: "zeus", at: 10)
        let inbox = derive([F.agent("zeus")], asks: F.threadMap([ask], context: "I checked the build"))

        let item = try #require(inbox.blocked.first)
        #expect(item.kind == .chatAsk(ask))
        #expect(item.context == "I checked the build")
        #expect(item.at == F.at(10))
        #expect(inbox.finished.isEmpty)
    }

    @Test func aChatPermissionRowIsAnAnswerableChatAsk() throws {
        let row = F.ask("m1", agent: "zeus", kind: .permission)
        let item = try #require(derive([F.agent("zeus")], asks: F.threadMap([row])).blocked.first)
        #expect(item.kind == .chatAsk(row))
    }

    @Test func aTerminalPermissionReasonCarriesToolAndDetail() throws {
        let reason = LeoAttentionReason(kind: .permission, tool: "Bash", detail: "rm -rf build", input: "rm -rf build && echo ok")
        let agent = F.agent("zeus", signal: F.signal(.needsInput, reason: reason, at: 5))

        let item = try #require(derive([agent]).blocked.first)

        #expect(item.kind == .permission(tool: "Bash", detail: "rm -rf build", input: "rm -rf build && echo ok"))
        #expect(item.at == F.at(5))
    }

    @Test func aQuestionOrElicitationReasonCarriesItsText() throws {
        let question = F.agent("a", signal: F.signal(.needsInput, reason: LeoAttentionReason(kind: .question, detail: "Which DB?")))
        let elicitation = F.agent("b", signal: F.signal(.needsInput, reason: LeoAttentionReason(kind: .elicitation, tool: "github")))
        let bare = F.agent("c", signal: F.signal(.needsInput))

        let kinds = Dictionary(uniqueKeysWithValues: derive([question, elicitation, bare]).blocked.map { ($0.id.name, $0.kind) })

        #expect(kinds["a"] == .question(text: "Which DB?"))
        #expect(kinds["b"] == .question(text: "github"))
        #expect(kinds["c"] == .question(text: nil))
    }

    @Test func aChatRowOutranksAPermissionReason() throws {
        let ask = F.ask("m1", agent: "zeus")
        let reason = LeoAttentionReason(kind: .permission, tool: "Bash")
        let agent = F.agent("zeus", signal: F.signal(.needsInput, reason: reason))

        let blocked = derive([agent], asks: F.threadMap([ask])).blocked

        #expect(blocked.map(\.kind) == [.chatAsk(ask)])
    }

    @Test func aChatAskBlocksEvenWhileTheAgentIsWorking() {
        let agent = F.agent("zeus", signal: F.signal(.working))
        #expect(derive([agent], asks: F.threadMap([F.ask("m1", agent: "zeus")])).blocked.count == 1)
    }

    @Test func projectLabelIsOmittedWhenItEqualsTheAgentName() throws {
        let inbox = derive([
            F.agent("zeus", project: "zeus", signal: F.signal(.finished, at: 1)),
            F.agent("hera", project: "olympus", signal: F.signal(.finished, at: 2)),
            F.agent("ares", project: nil, signal: F.signal(.finished, at: 3)),
        ])
        let labels = Dictionary(uniqueKeysWithValues: inbox.finished.map { ($0.id.name, $0.projectLabel) })

        #expect(labels == ["zeus": nil, "hera": "olympus", "ares": nil])
    }

    @Test func itemsCarryAgentAndMachine() throws {
        let item = try #require(derive([F.agent("zeus", signal: F.signal(.finished, at: 1))]).finished.first)
        #expect(item.agent == "zeus")
        #expect(item.machine == "mars")
        #expect(item.id == F.id("zeus"))
    }

    @Test func blockedIsOldestFirstAndFinishedNewestFirst() {
        let agents = [
            F.agent("b1", signal: F.signal(.needsInput, at: 20)),
            F.agent("b2", signal: F.signal(.needsInput, at: 10)),
            F.agent("f1", signal: F.signal(.finished, at: 5)),
            F.agent("f2", signal: F.signal(.finished, at: 50)),
            F.agent("b3"),
        ]
        let inbox = derive(agents, asks: F.threadMap([F.ask("m", agent: "b3", at: 15)]))

        #expect(inbox.blocked.map(\.id.name) == ["b2", "b3", "b1"])
        #expect(inbox.finished.map(\.id.name) == ["f2", "f1"])
    }

    @Test func aStaleAgentContributesNothing() {
        let stale = F.agent("zeus", signal: F.signal(.finished, at: 1), isStale: true)
        let staleAsk = F.agent("hera", isStale: true)

        let inbox = derive([stale, staleAsk], asks: F.threadMap([F.ask("m1", agent: "hera")]))

        #expect(inbox.blocked.isEmpty)
        #expect(inbox.finished.isEmpty)
    }

    @Test func erroredIsFinishedWithTheErrorFlagAndPreview() throws {
        let agents = [
            F.agent("ok", signal: F.signal(.finished, preview: "Done", at: 1)),
            F.agent("bad", signal: F.signal(.errored, preview: "Rate limited", at: 2)),
        ]
        let items = derive(agents).finished

        #expect(items.map(\.isError) == [true, false])
        #expect(items.map(\.kind) == [.finished(result: "Rate limited"), .finished(result: "Done")])
    }

    @Test func workingAndUnknownAgentsAreNotInTheInbox() {
        let inbox = derive([F.agent("a", signal: F.signal(.working)), F.agent("b", signal: F.signal(.unknown)), F.agent("c")])
        #expect(inbox.blocked.isEmpty && inbox.finished.isEmpty)
    }

    @Test func oneItemPerAgentWithMoreCountForExtraAsks() throws {
        let first = F.ask("m1", agent: "zeus", at: 1)
        let second = F.ask("m2", agent: "zeus", kind: .permission, at: 2)
        let third = F.ask("m3", agent: "zeus", at: 3)

        let item = try #require(derive([F.agent("zeus")], asks: F.threadMap([third, first, second])).blocked.first)

        #expect(item.kind == .chatAsk(first))
        #expect(item.moreCount == 2)
        #expect(derive([F.agent("zeus")], asks: F.threadMap([first])).blocked.first?.moreCount == 0)
    }

    @Test func aBlockedAgentHasNoFinishedItem() {
        let agent = F.agent("zeus", signal: F.signal(.finished, at: 1))
        let inbox = derive([agent], asks: F.threadMap([F.ask("m1", agent: "zeus")]))
        #expect(inbox.blocked.count == 1)
        #expect(inbox.finished.isEmpty)
    }

    @Test func asksForUnlistedAgentsAreIgnored() {
        #expect(derive([], asks: F.threadMap([F.ask("m1", agent: "ghost")])).blocked.isEmpty)
    }

    @Test func finishedItemsAreFlaggedUnreadByTheSeenState() throws {
        var seen = LeoInboxSeenState()
        seen.seed(host: F.host, seen: ["old": F.at(100)])
        let agents = [
            F.agent("old", signal: F.signal(.finished, at: 50)),
            F.agent("new", signal: F.signal(.finished, at: 60)),
        ]
        let items = derive(agents, seen: seen).finished

        #expect(Dictionary(uniqueKeysWithValues: items.map { ($0.id.name, $0.isUnread) }) == ["old": false, "new": true])
    }
}
