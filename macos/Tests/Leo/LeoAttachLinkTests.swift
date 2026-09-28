import AppKit
import Foundation
import Testing

@testable import Ghostty

/// B-006: attach tabs linked to sidebar rows -- focus -> highlight, live tab
/// counts, and click routing (focus the existing tab vs attach new).
@MainActor struct LeoAttachLinkTests {
    private let local = LeoAgentIdentity(host: .local, name: "worker")
    private let remote = LeoAgentIdentity(host: .remote("box"), name: "worker")
    private let other = LeoAgentIdentity(host: .local, name: "other")
    private let origin = LeoWindowID()

    // MARK: Coordinator link state

    @Test func linkStateCountsLiveAttachmentsPerIdentity() async {
        let host = FakeAttachTabHost()
        var states: [LeoAttachLinkState] = []
        let coordinator = makeCoordinator(host: host) { states.append($0) }
        await coordinator.attach(identity: local, from: origin, disposition: .reuseOrTab)
        _ = await coordinator.attach(identity: local, request: splitRequest())
        await coordinator.attach(identity: other, from: origin, disposition: .newWindow)

        #expect(coordinator.linkState.tabCounts == [id(local): 2, id(other): 1])
        #expect(states.last == coordinator.linkState)

        await host.emitAndWait(.processExited(host.handles[0]))
        #expect(coordinator.linkState.tabCounts == [id(local): 1, id(other): 1], "an exited attach shows a placeholder, not the agent")

        await host.emitAndWait(.closed(host.handles[2]))
        #expect(coordinator.linkState.tabCounts == [id(local): 1])
    }

    @Test func linkStateReportsTheFocusedRow() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: local, from: origin, disposition: .reuseOrTab)

        await host.emitAndWait(.focusChanged(host.handles[0]))
        #expect(coordinator.linkState.focused == id(local))

        await host.emitAndWait(.focusChanged(nil))
        #expect(coordinator.linkState.focused == nil)
    }

    @Test func localAndRemoteAgentsWithTheSameNameAreDistinct() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: local, from: origin, disposition: .reuseOrTab)
        await coordinator.attach(identity: remote, from: origin, disposition: .reuseOrTab)

        await host.emitAndWait(.focusChanged(host.handles[1]))

        #expect(host.tabCalls.count == 2)
        #expect(coordinator.linkState.tabCounts == [id(local): 1, id(remote): 1])
        #expect(coordinator.linkState.focused == id(remote))
        #expect(coordinator.focusExisting(remote))
        #expect(host.focused == [host.handles[1]])
    }

    // MARK: Focus the existing tab

    @Test func focusExistingFocusesTheMostRecentlyFocusedAttachment() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: local, from: origin, disposition: .reuseOrTab)
        _ = await coordinator.attach(identity: local, request: splitRequest())
        await host.emitAndWait(.focusChanged(host.handles[0]))
        await host.emitAndWait(.focusChanged(nil))

        #expect(coordinator.focusExisting(local))
        #expect(host.focused == [host.handles[0]], "the tab focused last wins over the split opened last")
    }

    @Test func reuseAttachFocusesTheMostRecentlyFocusedAttachment() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: local, from: origin, disposition: .reuseOrTab)
        _ = await coordinator.attach(identity: local, request: splitRequest())
        await host.emitAndWait(.focusChanged(host.handles[0]))

        await coordinator.attach(identity: local, from: origin, disposition: .reuseOrTab)

        #expect(host.tabCalls.count == 1)
        #expect(host.focused == [host.handles[0]])
    }

    @Test func focusExistingIsFalseWithoutALiveAttachment() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        #expect(!coordinator.focusExisting(local))

        await coordinator.attach(identity: local, from: origin, disposition: .reuseOrTab)
        await host.emitAndWait(.processExited(host.handles[0]))

        #expect(!coordinator.focusExisting(local))
        #expect(host.focused.isEmpty)
    }

    @Test func closingTheMostRecentSplitFallsBackToTheNextLiveOne() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: local, from: origin, disposition: .reuseOrTab)
        _ = await coordinator.attach(identity: local, request: splitRequest())
        _ = await coordinator.attach(identity: local, request: splitRequest())
        await host.emitAndWait(.focusChanged(host.handles[1]))
        await host.emitAndWait(.focusChanged(host.handles[0]))

        await host.emitAndWait(.closed(host.handles[0]))

        #expect(coordinator.focusExisting(local))
        #expect(host.focused == [host.handles[1]], "MRU order is handles[2], handles[1], handles[0]; [0] closed")
    }

    @Test func focusExistingSkipsAnExitedMostRecentHandle() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: local, from: origin, disposition: .reuseOrTab)
        _ = await coordinator.attach(identity: local, request: splitRequest())
        await host.emitAndWait(.processExited(host.handles[1]))

        #expect(coordinator.focusExisting(local))
        #expect(host.focused == [host.handles[0]])
    }

    @Test func returnGoesThroughReuseOrTabAndFocusesTheLiveTab() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        var dispositions: [AttachDisposition] = []
        let returnKey = { (row: LeoAgentRow) in
            LeoAttachActivation.activate(row: row, modifierFlags: []) { _, disposition in dispositions.append(disposition) }
        }
        await coordinator.attach(identity: local, from: origin, disposition: .reuseOrTab)

        returnKey(row(local))
        for disposition in dispositions { await coordinator.attach(identity: local, from: origin, disposition: disposition) }

        #expect(dispositions == [.reuseOrTab])
        #expect(host.tabCalls.count == 1)
        #expect(host.windowCalls.isEmpty)
        #expect(host.focused == [host.handles[0]])
    }

    // MARK: Sidebar model

    @Test func aCountOnlyChangeLeavesTheSelectionAlone() {
        let model = makeModel()
        model.receiveAttachLinks(LeoAttachLinkState(focused: id(local), tabCounts: [id(local): 1]))
        model.selection = id(other)

        model.receiveAttachLinks(LeoAttachLinkState(focused: id(local), tabCounts: [id(local): 2]))

        #expect(model.selection == id(other))
    }

    @Test func anExplicitRowClickWinsOverTheActivatedWindowsFocus() {
        let model = makeModel()
        model.selection = id(other)
        // Clicking `other` in a non-key window: the window becomes key and
        // reports its own focused attach before the click completes.
        model.receiveAttachLinks(LeoAttachLinkState(focused: id(local), tabCounts: [id(local): 1]))

        model.rowClicked(row(other))

        #expect(model.selection == id(other))
    }

    @Test func optionClickDoesNotFocusTheLiveTab() {
        let model = makeModel()
        var focusRequests: [LeoAgentRow.ID] = []
        model.focusExistingRequested = { row, _ in focusRequests.append(row.id) }
        model.receiveAttachLinks(LeoAttachLinkState(focused: nil, tabCounts: [id(local): 1]))

        model.rowClicked(row(local), modifierFlags: .option)

        #expect(focusRequests.isEmpty)
    }

    @Test func switchingHostsBackReselectsTheFocusedRow() {
        let model = makeModel()
        model.receiveAttachLinks(LeoAttachLinkState(focused: id(local), tabCounts: [id(local): 1]))
        model.receive(LeoSidebarSnapshot(rows: [row(remote)], connectivity: .connected, generation: 2))
        #expect(model.selection == nil)

        model.receive(LeoSidebarSnapshot(rows: [row(local), row(other)], connectivity: .connected, generation: 3))

        #expect(model.selection == id(local))
    }

    @Test func aRefreshThatStillShowsTheFocusedRowKeepsTheSelection() {
        let model = makeModel()
        model.receiveAttachLinks(LeoAttachLinkState(focused: id(local), tabCounts: [id(local): 1]))
        model.selection = id(other)

        model.receive(LeoSidebarSnapshot(rows: [row(local), row(other)], connectivity: .connected, generation: 2))

        #expect(model.selection == id(other))
    }

    @Test func focusedRowBecomesTheSelection() {
        let model = makeModel()
        model.selection = id(other)

        model.receiveAttachLinks(LeoAttachLinkState(focused: id(local), tabCounts: [id(local): 1]))

        #expect(model.selection == id(local))
        #expect(model.tabCount(for: id(local)) == 1)
        #expect(model.tabCount(for: id(other)) == 0)
    }

    @Test func focusLeavingAttachmentsOrOnAnotherHostKeepsTheSelection() {
        let model = makeModel()
        model.selection = id(other)

        model.receiveAttachLinks(LeoAttachLinkState(focused: nil, tabCounts: [:]))
        #expect(model.selection == id(other))

        model.receiveAttachLinks(LeoAttachLinkState(focused: id(remote), tabCounts: [id(remote): 1]))
        #expect(model.selection == id(other), "never select a row the sidebar is not showing")
    }

    @Test func clickingARowWithALiveTabFocusesIt() {
        let model = makeModel()
        var focusRequests: [LeoAgentRow.ID] = []
        model.focusExistingRequested = { row, _ in focusRequests.append(row.id) }
        model.receiveAttachLinks(LeoAttachLinkState(focused: nil, tabCounts: [id(local): 2]))

        model.rowClicked(row(local))
        model.rowClicked(row(other))

        #expect(focusRequests == [id(local)], "a row without a live tab is attached instead (B-049), never focused")
    }

    // MARK: Helpers

    private func id(_ identity: LeoAgentIdentity) -> LeoAgentRow.ID { LeoAgentRow.ID(host: identity.host, name: identity.name) }

    private func row(_ identity: LeoAgentIdentity) -> LeoAgentRow {
        LeoAgentRow(host: identity.host, name: identity.name, template: nil, status: .running, activity: .idle, actionDetail: nil)
    }

    private func makeModel() -> LeoSidebarModel {
        LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: [row(local), row(other)], connectivity: .connected, generation: 1))
    }

    private func splitRequest() -> LeoSurfaceRequest {
        LeoSurfaceRequest(origin: origin, disposition: .split(.right), splitSourceSurface: UUID())
    }

    private func makeCoordinator(
        host: FakeAttachTabHost,
        linkStateChanged: @escaping (LeoAttachLinkState) -> Void = { _ in }
    ) -> LeoAttachCoordinator {
        LeoAttachCoordinator(
            host: host,
            executable: { "/leo" },
            remoteCommandBuilder: { "ssh box leo attach \($0.name)" },
            report: { _ in },
            lifecycleEventHandled: { host.acknowledge($0) },
            linkStateChanged: linkStateChanged
        )
    }
}
