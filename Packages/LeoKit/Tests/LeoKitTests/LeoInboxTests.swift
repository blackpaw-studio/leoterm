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

    @Test(arguments: ["", "  \n", "NO_REPLY", "  no_reply \n", "NO_REPLY.", "HEARTBEAT_OK", "NO_RESPONSE"])
    func aSentinelPreviewNeverReachesTheFinishedResult(_ sentinel: String) throws {
        let agent = Fx.agent("trader", signal: Fx.signal(.finished, preview: sentinel, at: 1))

        let item = try #require(derive([agent]).finished.first)

        #expect(item.kind == .finished(result: nil))
    }

    @Test(arguments: ["Replied to Sam", "No reply needed from Sam", "OK", "NO"])
    func aRealPreviewIsKept(_ preview: String) throws {
        let agent = Fx.agent("trader", signal: Fx.signal(.finished, preview: preview, at: 1))

        let item = try #require(derive([agent]).finished.first)

        #expect(item.kind == .finished(result: preview))
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

    // MARK: Brief

    @Test func theBriefRidesOnItsItem() throws {
        let brief = LeoAgentBrief(goal: "g", status: "waiting on CI")
        let signal = Fx.signal(.finished, preview: "done", at: 5)
        let item = try #require(derive([Fx.agent("zeus", signal: signal, brief: brief)]).finished.first)
        #expect(item.brief == brief)
    }

    @Test func secondaryLinePrefersTheBriefStatusOverContext() throws {
        let ask = Fx.ask("m1", agent: "zeus")
        let brief = LeoAgentBrief(status: "  next: rebase ")
        let item = try #require(derive([Fx.agent("zeus", brief: brief)], asks: Fx.threadMap([ask], context: "ctx")).blocked.first)
        #expect(item.secondaryLine == "next: rebase")
    }

    @Test func secondaryLineFallsBackToContextWhenTheBriefHasNoStatus() throws {
        let ask = Fx.ask("m1", agent: "zeus")
        let noStatus = LeoAgentBrief(goal: "g", status: " ")
        let item = try #require(derive([Fx.agent("zeus", brief: noStatus)], asks: Fx.threadMap([ask], context: "ctx")).blocked.first)
        #expect(item.secondaryLine == "ctx")
        let bare = try #require(derive([Fx.agent("hera")], asks: Fx.threadMap([Fx.ask("m2", agent: "hera")])).blocked.first)
        #expect(bare.secondaryLine == nil)
    }

    // MARK: Dismiss

    private func dismissed(_ agents: [LeoInboxAgent], asks: [LeoAgentID: LeoOpenAskThread] = [:], at now: TimeInterval) -> LeoInboxSeenState {
        var seen = LeoInboxSeenState()
        seen.seed(host: Fx.host, seen: [:])
        for item in derive(agents, asks: asks, seen: seen).blocked { seen.dismiss(item, now: Fx.at(now)) }
        return seen
    }

    @Test func dismissingABlockedChatAskHidesItAndLeavesTheBadge() {
        let agents = [Fx.agent("zeus")]
        let asks = Fx.threadMap([Fx.ask("m1", agent: "zeus", at: 10)])
        let seen = dismissed(agents, asks: asks, at: 20)

        let inbox = derive(agents, asks: asks, seen: seen)

        #expect(inbox.blocked.isEmpty)
        #expect(inbox.badge == .none)
    }

    @Test func aNewAskIdResurfacesADismissedAgent() throws {
        let agents = [Fx.agent("zeus")]
        let first = Fx.ask("m1", agent: "zeus", at: 10)
        let seen = dismissed(agents, asks: Fx.threadMap([first]), at: 20)

        let second = Fx.ask("m2", agent: "zeus", at: 30)
        let item = try #require(derive(agents, asks: Fx.threadMap([first, second]), seen: seen).blocked.first)

        #expect(item.kind == .chatAsk(first))
        #expect(item.moreCount == 1)
    }

    @Test func aFreshNeedsInputTransitionResurfacesADismissedPrompt() {
        let reason = LeoAttentionReason(kind: .permission, tool: "Bash")
        let first = Fx.agent("zeus", signal: Fx.signal(.needsInput, 1, reason: reason, at: 10))
        let seen = dismissed([first], at: 20)
        let working = Fx.agent("zeus", signal: Fx.signal(.working, 2, at: 25))
        let again = Fx.agent("zeus", signal: Fx.signal(.needsInput, 3, reason: reason, at: 30))

        #expect(derive([first], seen: seen).blocked.isEmpty)
        #expect(derive([working], seen: seen).blocked.isEmpty)
        #expect(derive([again], seen: seen).blocked.count == 1)
    }

    @Test func aDismissedItemStaysHiddenWhileUnchanged() {
        let ask = Fx.ask("m1", agent: "zeus", at: 10)
        let blocked = Fx.agent("zeus", signal: Fx.signal(.needsInput, 1, at: 10))
        let seen = dismissed([blocked], asks: Fx.threadMap([ask]), at: 20)
        let working = Fx.agent("zeus", signal: Fx.signal(.working, 2, at: 15))
        let sameRevision = Fx.agent("zeus", signal: Fx.signal(.needsInput, 1, at: 10))

        #expect(derive([working], asks: Fx.threadMap([ask]), seen: seen).blocked.isEmpty)
        #expect(derive([sameRevision], seen: seen).blocked.isEmpty)
    }

    @Test func aDismissFromAnotherDeviceHidesTheItem() {
        let agents = [Fx.agent("zeus")]
        let asks = Fx.threadMap([Fx.ask("m1", agent: "zeus", at: 10)])
        var seen = LeoInboxSeenState()
        seen.seed(host: Fx.host, seen: [:])
        #expect(derive(agents, asks: asks, seen: seen).blocked.count == 1)

        seen.apply(host: Fx.host, agent: "zeus", seenAt: Fx.at(40))

        #expect(derive(agents, asks: asks, seen: seen).blocked.isEmpty)
    }

    @Test func localModeDismissResurfacesOnRevisionChange() {
        var seen = LeoInboxSeenState()
        seen.seed(host: Fx.host, seen: nil)
        let first = Fx.agent("zeus", signal: Fx.signal(.needsInput, 4, at: 10))
        let item = derive([first], seen: seen).blocked[0]

        seen.dismiss(item, now: Fx.at(20))

        #expect(derive([first], seen: seen).blocked.isEmpty)
        #expect(derive([Fx.agent("zeus", signal: Fx.signal(.needsInput, 5, at: 30))], seen: seen).blocked.count == 1)
        #expect(derive([Fx.agent("zeus", signal: Fx.signal(.needsInput, 4, at: 10), bootID: "restarted")], seen: seen).blocked.count == 1)
    }

    @Test func aSamePromptRevisionBumpStaysDismissed() {
        // The daemon bumps the revision for subagent and dispatch counts without moving `at`.
        let reason = LeoAttentionReason(kind: .permission, tool: "Bash")
        let first = Fx.agent("zeus", signal: Fx.signal(.needsInput, 1, reason: reason, at: 10))
        let seen = dismissed([first], at: 20)
        let bumped = Fx.agent("zeus", signal: Fx.signal(.needsInput, 2, reason: reason, at: 10))

        #expect(derive([bumped], seen: seen).blocked.isEmpty)
    }

    @Test func localModeANewAskInTheSameTurnResurfaces() {
        var seen = LeoInboxSeenState()
        seen.seed(host: Fx.host, seen: nil)
        let agents = [Fx.agent("zeus", signal: Fx.signal(.working, 4))]
        let first = Fx.ask("m1", agent: "zeus", at: 10)
        seen.dismiss(derive(agents, asks: Fx.threadMap([first]), seen: seen).blocked[0], now: Fx.at(20))

        let second = Fx.ask("m2", agent: "zeus", at: 30)

        #expect(derive(agents, asks: Fx.threadMap([first]), seen: seen).blocked.isEmpty)
        #expect(derive(agents, asks: Fx.threadMap([first, second]), seen: seen).blocked.count == 1)
    }

    @Test func aBlockedItemWithoutATimeIsNeverTreatedAsDismissed() {
        var seen = LeoInboxSeenState()
        seen.seed(host: Fx.host, seen: ["zeus": Fx.at(100)])
        let agent = Fx.agent("zeus", signal: Fx.signal(.needsInput, 1, at: nil))

        #expect(derive([agent], seen: seen).blocked.count == 1)
    }

    private func seededAsks(_ asks: [LeoChatMessage] = []) -> LeoOpenAsks {
        var openAsks = LeoOpenAsks()
        openAsks.seed(host: Fx.host, messages: asks, complete: true)
        return openAsks
    }

    @Test func openingABlockedAgentNeverMarksItSeen() {
        let openAsks = seededAsks([Fx.ask("m1", agent: "zeus")])
        let prompt = Fx.agent("hera", signal: Fx.signal(.needsInput, 1, at: 10))
        let finished = Fx.agent("ares", signal: Fx.signal(.finished, 1, at: 10))
        let working = Fx.agent("nike", signal: Fx.signal(.working, 1))

        #expect(!LeoInbox.marksSeenOnOpen(Fx.agent("zeus"), openAsks: openAsks))
        #expect(!LeoInbox.marksSeenOnOpen(prompt, openAsks: openAsks))
        #expect(LeoInbox.marksSeenOnOpen(finished, openAsks: openAsks))
        #expect(LeoInbox.marksSeenOnOpen(working, openAsks: openAsks))
        #expect(LeoInbox.marksSeenOnOpen(Fx.agent("pan"), openAsks: openAsks))
    }

    @Test func openingBeforeAHostsAsksLoadNeverMarksSeen() {
        let finished = Fx.agent("ares", signal: Fx.signal(.finished, 1, at: 10))
        var openAsks = LeoOpenAsks()

        #expect(!LeoInbox.marksSeenOnOpen(finished, openAsks: openAsks))

        // A live event is not a load: the host's other asks may still be unknown.
        openAsks.apply(host: Fx.host, event: .message(Fx.ask("m1", agent: "zeus")))
        #expect(!LeoInbox.marksSeenOnOpen(finished, openAsks: openAsks))

        openAsks.seed(host: Fx.host, messages: [], complete: true)
        #expect(LeoInbox.marksSeenOnOpen(finished, openAsks: openAsks))

        openAsks.disconnect(host: Fx.host)
        #expect(!LeoInbox.marksSeenOnOpen(finished, openAsks: openAsks))
    }

    @Test func openingAnUnknownAgentNeverMarksSeen() {
        #expect(!LeoInbox.marksSeenOnOpen(nil, openAsks: seededAsks()))
    }

    @Test func aStoppedAgentContributesNothing() {
        let signal = Fx.signal(.needsInput, 1, at: 5)
        let ask = Fx.threadMap([Fx.ask("m1", agent: "zeus")])
        let agents = [
            Fx.agent("zeus", signal: signal, isStopped: true),
            Fx.agent("hera", signal: Fx.signal(.needsInput, 1, at: 5), isStopped: true),
            Fx.agent("ares", signal: Fx.signal(.finished, 1, at: 5), isStopped: true),
        ]

        #expect(derive(agents, asks: ask) == .empty)
    }
}
