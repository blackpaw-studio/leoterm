import AppKit
import Testing

@testable import Ghostty

/// B-049: one click on a row takes you into its agent. A running agent is
/// attached (or its open tab focused); an agent that isn't running asks
/// "Start <name>?" first, and attaches only once the daemon reports it
/// running. Return is the same click; arrow keys only select.
@MainActor struct LeoRowClickStartPromptTests {
    private let origin = LeoWindowID()
    private let otherWindow = LeoWindowID()

    private final class Log {
        var attaches: [(LeoAgentRow.ID, LeoWindowID, AttachDisposition)] = []
        var focusRequests: [LeoAgentRow.ID] = []
        var starts: [LeoAgentRow.ID] = []
        var startCompletions: [(Bool) -> Void] = []
        var dispositions: [AttachDisposition] { attaches.map(\.2) }
    }

    private func row(_ name: String = "worker", _ status: LeoAgentStatus = .running) -> LeoAgentRow {
        LeoAgentRow(host: .local, name: name, template: nil, status: status, activity: .idle, actionDetail: nil)
    }

    private func makeModel(
        _ rows: [LeoAgentRow],
        tabs: [LeoAgentRow.ID: Int] = [:],
        connectivity: LeoConnectivity = .connected
    ) -> (LeoSidebarModel, Log) {
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: rows, connectivity: connectivity, generation: 1))
        let log = Log()
        model.attachRequested = { log.attaches.append(($0.id, $1, $2)) }
        model.focusExistingRequested = { row, _ in log.focusRequests.append(row.id) }
        model.startRequested = { row, completion in
            log.starts.append(row.id)
            log.startCompletions.append(completion)
        }
        if !tabs.isEmpty { model.receiveAttachLinks(LeoAttachLinkState(focused: nil, tabCounts: tabs)) }
        return (model, log)
    }

    private func report(_ model: LeoSidebarModel, _ rows: [LeoAgentRow]) {
        model.receive(LeoSidebarSnapshot(rows: rows, connectivity: .connected, generation: model.snapshot.generation + 1))
    }

    // MARK: Running agents

    @Test func singleClickOnARunningRowWithoutATabAttachesOnce() {
        let worker = row()
        let (model, log) = makeModel([worker])

        model.rowClicked(worker, from: origin)

        #expect(log.attaches.map(\.0) == [worker.id])
        #expect(log.attaches.first?.1 == origin)
        #expect(log.dispositions == [.reuseOrTab])
        #expect(log.focusRequests.isEmpty)
        #expect(model.startPrompt(in: origin) == nil)
    }

    @Test func singleClickOnARunningRowWithATabFocusesIt() {
        let worker = row()
        let (model, log) = makeModel([worker], tabs: [worker.id: 1])

        model.rowClicked(worker, from: origin)

        #expect(log.focusRequests == [worker.id])
        #expect(log.attaches.isEmpty)
    }

    @Test func commandClickStillForcesANewTab() {
        let worker = row()
        let (model, log) = makeModel([worker], tabs: [worker.id: 1])

        model.rowClicked(worker, modifierFlags: .command, from: origin)

        #expect(log.dispositions == [.newTab])
        #expect(log.focusRequests.isEmpty)
    }

    @Test func optionClickDefersToTheDoubleClicksNewWindow() {
        let worker = row()
        let (model, log) = makeModel([worker])

        model.rowClicked(worker, modifierFlags: .option, clickCount: 1, from: origin)
        #expect(log.attaches.isEmpty)

        model.rowClicked(worker, modifierFlags: .option, clickCount: 2, from: origin)
        #expect(log.dispositions == [.newWindow])
    }

    @Test func theSecondClickOfADoubleClickNeverAttachesAgain() {
        let worker = row()
        let (model, log) = makeModel([worker])

        model.rowClicked(worker, clickCount: 1, from: origin)
        model.rowClicked(worker, clickCount: 2, from: origin)

        #expect(log.dispositions == [.reuseOrTab])
        #expect(log.focusRequests.isEmpty)
    }

    // MARK: Agents that aren't running

    @Test(arguments: [LeoAgentStatus.stopped, .unknown("error")])
    func clickOnAnAgentThatIsNotRunningAsksToStartIt(status: LeoAgentStatus) {
        let agent = row("scratch", status)
        let (model, log) = makeModel([agent])

        model.rowClicked(agent, from: origin)

        let prompt = model.startPrompt(in: origin)
        #expect(prompt?.agent == agent.id)
        #expect(prompt?.phase == .confirm)
        #expect(model.selection == agent.id)
        #expect(log.starts.isEmpty, "never start without asking")
        #expect(log.attaches.isEmpty)
        #expect(log.focusRequests.isEmpty)
    }

    @Test func aStoppedAgentWithATabStillAsks() {
        let agent = row("scratch", .stopped)
        let (model, log) = makeModel([agent], tabs: [agent.id: 1])

        model.rowClicked(agent, from: origin)

        #expect(model.startPrompt(in: origin)?.phase == .confirm)
        #expect(log.focusRequests.isEmpty)
    }

    @Test func aStartingAgentWaitsForRunningWithoutStartingItAgain() {
        let agent = row("scratch", .starting)
        let (model, log) = makeModel([agent])

        model.rowClicked(agent, from: origin)
        #expect(model.startPrompt(in: origin)?.phase == .waiting)
        #expect(log.starts.isEmpty)

        report(model, [row("scratch", .running)])

        #expect(log.dispositions == [.reuseOrTab])
        #expect(model.startPrompt(in: origin) == nil)
    }

    @Test func startStartsThroughTheDaemonAndAttachesOnceRunningIsReported() throws {
        let agent = row("scratch", .stopped)
        let (model, log) = makeModel([agent])
        model.rowClicked(agent, from: origin)
        let prompt = try #require(model.startPrompt(in: origin))

        model.confirmStart(prompt.id)

        #expect(log.starts == [agent.id])
        #expect(model.startPrompt(in: origin)?.phase == .waiting)
        log.startCompletions.first?(true)
        report(model, [row("scratch", .stopped)])
        report(model, [row("scratch", .starting)])
        #expect(log.attaches.isEmpty, "attach only once the daemon reports running")

        report(model, [row("scratch", .running)])

        #expect(log.attaches.map(\.0) == [agent.id])
        #expect(log.attaches.first?.1 == origin)
        #expect(log.dispositions == [.reuseOrTab])
        #expect(model.startPrompt(in: origin) == nil)
        report(model, [row("scratch", .running)])
        #expect(log.attaches.count == 1)
    }

    @Test func runningReportedBeforeTheStartCallReturnsStillAttachesOnce() throws {
        let agent = row("scratch", .stopped)
        let (model, log) = makeModel([agent])
        model.rowClicked(agent, from: origin)
        model.confirmStart(try #require(model.startPrompt(in: origin)).id)

        report(model, [row("scratch", .running)])
        log.startCompletions.first?(true)

        #expect(log.dispositions == [.reuseOrTab])
    }

    @Test func confirmingTwiceStartsOnce() throws {
        let agent = row("scratch", .stopped)
        let (model, log) = makeModel([agent])
        model.rowClicked(agent, from: origin)
        let prompt = try #require(model.startPrompt(in: origin))

        model.confirmStart(prompt.id)
        model.confirmStart(prompt.id)

        #expect(log.starts == [agent.id])
    }

    @Test func commandClickOnAStoppedAgentAttachesANewTabAfterStart() throws {
        let agent = row("scratch", .stopped)
        let (model, log) = makeModel([agent])
        model.rowClicked(agent, modifierFlags: .command, from: origin)
        model.confirmStart(try #require(model.startPrompt(in: origin)).id)

        report(model, [row("scratch", .running)])

        #expect(log.dispositions == [.newTab])
    }

    @Test func aFailedStartNeverAttaches() throws {
        let agent = row("scratch", .stopped)
        let (model, log) = makeModel([agent])
        model.rowClicked(agent, from: origin)
        model.confirmStart(try #require(model.startPrompt(in: origin)).id)

        log.startCompletions.first?(false)

        #expect(model.startPrompt(in: origin) == nil)
        report(model, [row("scratch", .running)])
        #expect(log.attaches.isEmpty)
    }

    @Test func cancelLeavesTheAgentAndTabsAlone() throws {
        let agent = row("scratch", .stopped)
        let (model, log) = makeModel([agent], tabs: [agent.id: 1])
        model.rowClicked(agent, from: origin)

        model.cancelStartPrompt(try #require(model.startPrompt(in: origin)).id)

        #expect(model.startPrompt(in: origin) == nil)
        #expect(log.starts.isEmpty)
        #expect(log.attaches.isEmpty)
        #expect(log.focusRequests.isEmpty)
    }

    @Test func cancellingWhileWaitingNeverAttaches() throws {
        let agent = row("scratch", .stopped)
        let (model, log) = makeModel([agent])
        model.rowClicked(agent, from: origin)
        let prompt = try #require(model.startPrompt(in: origin))
        model.confirmStart(prompt.id)

        model.cancelStartPrompt(prompt.id)
        log.startCompletions.first?(true)
        report(model, [row("scratch", .running)])

        #expect(log.attaches.isEmpty)
        #expect(model.startPrompt(in: origin) == nil)
    }

    @Test func theAgentDisappearingEndsTheWait() throws {
        let agent = row("scratch", .stopped)
        let (model, log) = makeModel([agent, row("other")])
        model.rowClicked(agent, from: origin)
        model.confirmStart(try #require(model.startPrompt(in: origin)).id)

        report(model, [row("other")])
        report(model, [row("other"), row("scratch", .running)])

        #expect(model.startPrompt(in: origin) == nil)
        #expect(log.attaches.isEmpty)
    }

    @Test(arguments: [NSEvent.ModifierFlags(), .command, .option])
    func aDoubleClickOnAStoppedAgentAsksOnce(modifierFlags: NSEvent.ModifierFlags) throws {
        let agent = row("scratch", .stopped)
        let (model, log) = makeModel([agent])

        model.rowClicked(agent, modifierFlags: modifierFlags, clickCount: 1, from: origin)
        let first = model.startPrompt(in: origin)
        model.rowClicked(agent, modifierFlags: modifierFlags, clickCount: 2, from: origin)

        let prompt = try #require(model.startPrompt(in: origin))
        if let first { #expect(prompt.id == first.id, "the second click must not ask again") }
        #expect(model.startPrompts.count == 1)
        #expect(log.attaches.isEmpty)
        #expect(log.starts.isEmpty)
    }

    @Test func anOpenPromptIsNotReplacedByAnotherClick() throws {
        let scratch = row("scratch", .stopped)
        let other = row("other", .stopped)
        let (model, _) = makeModel([scratch, other])
        model.rowClicked(scratch, from: origin)
        let prompt = try #require(model.startPrompt(in: origin))

        model.rowClicked(other, from: origin)

        #expect(model.startPrompt(in: origin) == prompt)
    }

    @Test func promptsBelongToTheWindowClickedIn() throws {
        let agent = row("scratch", .stopped)
        let (model, _) = makeModel([agent])

        model.rowClicked(agent, from: origin)

        #expect(model.startPrompt(in: origin) != nil)
        #expect(model.startPrompt(in: otherWindow) == nil)
    }

    /// The sheet's own disappearance cancels by its prompt's id, so a sheet
    /// that finishes closing after a newer prompt opened leaves that one.
    @Test func aStaleCancelLeavesANewerPromptAlone() throws {
        let agent = row("scratch", .stopped)
        let (model, _) = makeModel([agent])
        model.rowClicked(agent, from: origin)
        let old = try #require(model.startPrompt(in: origin))
        model.cancelStartPrompt(old.id)
        model.rowClicked(agent, from: origin)
        let newer = try #require(model.startPrompt(in: origin))

        model.cancelStartPrompt(old.id)

        #expect(model.startPrompt(in: origin) == newer)
    }

    @Test func aClickWithoutAWindowNeverAsks() {
        let agent = row("scratch", .stopped)
        let (model, _) = makeModel([agent])

        model.rowClicked(agent)

        #expect(model.startPrompts.isEmpty)
    }

    @Test func clicksAreInertWhileDisconnected() {
        let agent = row("scratch", .stopped)
        let worker = row()
        let (model, log) = makeModel([agent, worker], connectivity: .disconnected(reason: "gone", isRetrying: false))

        model.rowClicked(agent, from: origin)
        model.rowClicked(worker, from: origin)

        #expect(model.startPrompts.isEmpty)
        #expect(log.attaches.isEmpty)
    }

    // MARK: Keyboard

    @Test func arrowKeysOnlySelect() {
        let agent = row("scratch", .stopped)
        let worker = row()
        let (model, log) = makeModel([agent, worker])

        model.userSelected(agent.id)
        model.userSelected(worker.id)

        #expect(model.selection == worker.id)
        #expect(model.startPrompts.isEmpty)
        #expect(log.attaches.isEmpty)
        #expect(log.focusRequests.isEmpty)
    }

    @Test func returnOnARunningRowActsLikeAClick() {
        let worker = row()
        let (model, log) = makeModel([worker])
        model.userSelected(worker.id)

        model.activateSelection(from: origin)

        #expect(log.dispositions == [.reuseOrTab])
    }

    @Test func returnOnARowWithATabFocusesIt() {
        let worker = row()
        let (model, log) = makeModel([worker], tabs: [worker.id: 1])
        model.userSelected(worker.id)

        model.activateSelection(from: origin)

        #expect(log.focusRequests == [worker.id])
        #expect(log.attaches.isEmpty)
    }

    @Test func returnOnAStoppedRowAsksToStartIt() {
        let agent = row("scratch", .stopped)
        let (model, log) = makeModel([agent])
        model.userSelected(agent.id)

        model.activateSelection(from: origin)

        #expect(model.startPrompt(in: origin)?.agent == agent.id)
        #expect(log.starts.isEmpty)
    }

    @Test func returnWithoutASelectionDoesNothing() {
        let (model, log) = makeModel([row()])

        model.activateSelection(from: origin)

        #expect(log.attaches.isEmpty)
        #expect(model.startPrompts.isEmpty)
    }
}

/// The sheet stays put while its prompt moves from asking to waiting.
@MainActor struct LeoStartPromptSheetItemTests {
    @Test func theSheetItemIsTheSameAcrossPhases() {
        let prompt = LeoStartPrompt(
            id: UUID(), agent: LeoAgentRow.ID(host: .local, name: "scratch"), origin: LeoWindowID(),
            disposition: .reuseOrTab, phase: .confirm)

        #expect(LeoStartPromptSheetItem(prompt: prompt) == LeoStartPromptSheetItem(prompt: prompt.with(phase: .waiting)))
        #expect(LeoStartPromptSheetItem(prompt: prompt) != LeoStartPromptSheetItem(prompt: LeoStartPrompt(
            id: UUID(), agent: prompt.agent, origin: prompt.origin, disposition: .reuseOrTab, phase: .confirm)))
    }
}
