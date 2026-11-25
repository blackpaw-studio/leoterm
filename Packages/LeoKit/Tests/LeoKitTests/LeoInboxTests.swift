import Foundation
import Testing

@testable import LeoKit

struct LeoInboxTests {
    typealias Fx = LeoInboxFixtures

    private func derive(
        _ agents: [LeoInboxAgent], asks: [LeoAgentID: LeoOpenAskThread] = [:], seen: LeoInboxSeenState = LeoInboxSeenState()
    ) -> LeoInbox {
        LeoInbox.derive(agents: agents, openAsks: asks, seen: seen)
    }

    @Test func anOpenChatAskIsBlockedWithItsQuestionAndContext() throws {
        let ask = Fx.ask("m1", agent: "zeus", at: 10)
        let inbox = derive([Fx.agent("zeus")], asks: Fx.threadMap([ask], context: "I checked the build"))

        let item = try #require(inbox.blocked.first)
        #expect(item.kind == .chatAsk(ask))
        #expect(item.context == "I checked the build")
        #expect(item.at == Fx.at(10))
        #expect(inbox.finished.isEmpty)
    }

    @Test func aChatPermissionRowIsAnAnswerableChatAsk() throws {
        let row = Fx.ask("m1", agent: "zeus", kind: .permission)
        let item = try #require(derive([Fx.agent("zeus")], asks: Fx.threadMap([row])).blocked.first)
        #expect(item.kind == .chatAsk(row))
    }

    @Test func aTerminalPermissionReasonCarriesToolAndDetail() throws {
        let reason = LeoAttentionReason(kind: .permission, tool: "Bash", detail: "rm -rf build", input: "rm -rf build && echo ok")
        let agent = Fx.agent("zeus", signal: Fx.signal(.needsInput, reason: reason, at: 5))

        let item = try #require(derive([agent]).blocked.first)

        #expect(item.kind == .permission(tool: "Bash", detail: "rm -rf build", input: "rm -rf build && echo ok"))
        #expect(item.at == Fx.at(5))
    }

    @Test func aQuestionOrElicitationReasonCarriesItsText() throws {
        let question = Fx.agent("a", signal: Fx.signal(.needsInput, reason: LeoAttentionReason(kind: .question, detail: "Which DB?")))
        let elicitation = Fx.agent("b", signal: Fx.signal(.needsInput, reason: LeoAttentionReason(kind: .elicitation, tool: "github")))
        let bare = Fx.agent("c", signal: Fx.signal(.needsInput))

        let kinds = Dictionary(uniqueKeysWithValues: derive([question, elicitation, bare]).blocked.map { ($0.id.name, $0.kind) })

        #expect(kinds["a"] == .question(text: "Which DB?"))
        #expect(kinds["b"] == .question(text: "github"))
        #expect(kinds["c"] == .question(text: nil))
    }

    @Test func aChatRowOutranksAPermissionReason() throws {
        let ask = Fx.ask("m1", agent: "zeus")
        let reason = LeoAttentionReason(kind: .permission, tool: "Bash")
        let agent = Fx.agent("zeus", signal: Fx.signal(.needsInput, reason: reason))

        let blocked = derive([agent], asks: Fx.threadMap([ask])).blocked

        #expect(blocked.map(\.kind) == [.chatAsk(ask)])
    }

    @Test func aChatAskBlocksEvenWhileTheAgentIsWorking() {
        let agent = Fx.agent("zeus", signal: Fx.signal(.working))
        #expect(derive([agent], asks: Fx.threadMap([Fx.ask("m1", agent: "zeus")])).blocked.count == 1)
    }

    @Test func projectLabelIsOmittedWhenItEqualsTheAgentName() throws {
        let inbox = derive([
            Fx.agent("zeus", project: "zeus", signal: Fx.signal(.finished, at: 1)),
            Fx.agent("hera", project: "olympus", signal: Fx.signal(.finished, at: 2)),
            Fx.agent("ares", project: nil, signal: Fx.signal(.finished, at: 3)),
        ])
        let labels = Dictionary(uniqueKeysWithValues: inbox.finished.map { ($0.id.name, $0.projectLabel) })

        #expect(labels == ["zeus": nil, "hera": "olympus", "ares": nil])
    }

    @Test func itemsCarryAgentAndMachine() throws {
        let item = try #require(derive([Fx.agent("zeus", signal: Fx.signal(.finished, at: 1))]).finished.first)
        #expect(item.agent == "zeus")
        #expect(item.machine == "mars")
        #expect(item.id == Fx.id("zeus"))
    }

    @Test func blockedIsOldestFirstAndFinishedNewestFirst() {
        let agents = [
            Fx.agent("b1", signal: Fx.signal(.needsInput, at: 20)),
            Fx.agent("b2", signal: Fx.signal(.needsInput, at: 10)),
            Fx.agent("f1", signal: Fx.signal(.finished, at: 5)),
            Fx.agent("f2", signal: Fx.signal(.finished, at: 50)),
            Fx.agent("b3"),
        ]
        let inbox = derive(agents, asks: Fx.threadMap([Fx.ask("m", agent: "b3", at: 15)]))

        #expect(inbox.blocked.map(\.id.name) == ["b2", "b3", "b1"])
        #expect(inbox.finished.map(\.id.name) == ["f2", "f1"])
    }

    @Test func aStaleAgentContributesNothing() {
        let stale = Fx.agent("zeus", signal: Fx.signal(.finished, at: 1), isStale: true)
        let staleAsk = Fx.agent("hera", isStale: true)

        let inbox = derive([stale, staleAsk], asks: Fx.threadMap([Fx.ask("m1", agent: "hera")]))

        #expect(inbox.blocked.isEmpty)
        #expect(inbox.finished.isEmpty)
    }

    @Test func erroredIsFinishedWithTheErrorFlagAndPreview() throws {
        let agents = [
            Fx.agent("ok", signal: Fx.signal(.finished, preview: "Done", at: 1)),
            Fx.agent("bad", signal: Fx.signal(.errored, preview: "Rate limited", at: 2)),
        ]
        let items = derive(agents).finished

        #expect(items.map(\.isError) == [true, false])
        #expect(items.map(\.kind) == [.finished(result: "Rate limited"), .finished(result: "Done")])
    }

    @Test func workingAndUnknownAgentsAreNotInTheInbox() {
        let inbox = derive([Fx.agent("a", signal: Fx.signal(.working)), Fx.agent("b", signal: Fx.signal(.unknown)), Fx.agent("c")])
        #expect(inbox.blocked.isEmpty && inbox.finished.isEmpty)
    }

    @Test func oneItemPerAgentWithMoreCountForExtraAsks() throws {
        let first = Fx.ask("m1", agent: "zeus", at: 1)
        let second = Fx.ask("m2", agent: "zeus", kind: .permission, at: 2)
        let third = Fx.ask("m3", agent: "zeus", at: 3)

        let item = try #require(derive([Fx.agent("zeus")], asks: Fx.threadMap([third, first, second])).blocked.first)

        #expect(item.kind == .chatAsk(first))
        #expect(item.moreCount == 2)
        #expect(derive([Fx.agent("zeus")], asks: Fx.threadMap([first])).blocked.first?.moreCount == 0)
    }

    @Test func aBlockedAgentHasNoFinishedItem() {
        let agent = Fx.agent("zeus", signal: Fx.signal(.finished, at: 1))
        let inbox = derive([agent], asks: Fx.threadMap([Fx.ask("m1", agent: "zeus")]))
        #expect(inbox.blocked.count == 1)
        #expect(inbox.finished.isEmpty)
    }

    @Test func asksForUnlistedAgentsAreIgnored() {
        #expect(derive([], asks: Fx.threadMap([Fx.ask("m1", agent: "ghost")])).blocked.isEmpty)
    }

    @Test func finishedItemsAreFlaggedUnreadByTheSeenState() throws {
        var seen = LeoInboxSeenState()
        seen.seed(host: Fx.host, seen: ["old": Fx.at(100)])
        let agents = [
            Fx.agent("old", signal: Fx.signal(.finished, at: 50)),
            Fx.agent("new", signal: Fx.signal(.finished, at: 60)),
        ]
        let items = derive(agents, seen: seen).finished

        #expect(Dictionary(uniqueKeysWithValues: items.map { ($0.id.name, $0.isUnread) }) == ["old": false, "new": true])
    }
}
