import AppKit
import Foundation
import Testing

@testable import Ghostty

/// B-055: one content area per window; the sidebar selects what's shown.
/// A row click, Return or a palette choice shows the agent in the window's
/// content area in place of what it showed; one agent is on screen in at
/// most one window, so an agent shown elsewhere brings that window forward
/// instead (as B-047 did for tabs); ⌘ opens a new window (D-104). Against
/// the fake host; the real swap is `LeoContentSwapIntegrationTests`.
@MainActor struct LeoContentAreaTests {
    private let worker = LeoAgentIdentity(host: .local, name: "worker")
    private let other = LeoAgentIdentity(host: .local, name: "other")
    private let remoteWorker = LeoAgentIdentity(host: .remote("box"), name: "worker")
    private let window = LeoWindowID()
    private let otherWindow = LeoWindowID()

    // MARK: Showing a row in the content area

    @Test func aRowIsShownInTheWindowsContentArea() async {
        let (host, coordinator) = make()

        await coordinator.attach(identity: worker, from: window, disposition: .content)

        #expect(host.contentCalls.map(\.origin) == [window])
        #expect(host.windowCalls.isEmpty)
        #expect(host.focused.isEmpty)
    }

    @Test func switchingRowsReplacesWhatTheContentAreaShows() async {
        let (host, coordinator) = make()
        await coordinator.attach(identity: worker, from: window, disposition: .content)

        await coordinator.attach(identity: other, from: window, disposition: .content)

        #expect(host.contentCalls.map(\.origin) == [window, window], "the same window, never a second one")
        #expect(host.windowCalls.isEmpty)
        #expect(host.shownInContent[window] == host.handles[1])
    }

    @Test func switchingAwayLetsTheOldAttachGoSoTheAgentCanBeShownAgain() async {
        let (host, coordinator) = make()
        await coordinator.attach(identity: worker, from: window, disposition: .content)
        await coordinator.attach(identity: other, from: window, disposition: .content)
        await host.emitAndWait(.closed(host.handles[0]))

        await coordinator.attach(identity: worker, from: window, disposition: .content)

        #expect(host.focused.isEmpty, "worker's surface left the window, so there is nothing to focus")
        #expect(host.contentCalls.count == 3)
        #expect(coordinator.linkState.attachCounts[LeoAgentRow.ID(host: .local, name: "worker")] == 1)
    }

    @Test func paletteChoiceOnAContentRequestShowsItThere() async {
        let (host, coordinator) = make()
        let router = makeRouter(coordinator)
        let request = LeoSurfaceRequest(origin: window, disposition: .content)
        router.begin(request)

        await router.choose(.agent(worker), for: request)

        #expect(host.contentCalls.map(\.requestID) == [request.id], "same request, so its inherited config applies")
    }

    @Test func aPlainShellFromTheContentAreaPaletteIsShownThere() async {
        let (host, coordinator) = make()

        _ = await coordinator.openPlainShell(request: LeoSurfaceRequest(origin: window, disposition: .content))

        #expect(host.contentCalls.map(\.origin) == [window])
        #expect(host.contentCalls.first?.command == "")
    }

    // MARK: One agent on screen in at most one window

    @Test(arguments: [AttachDisposition.content, .newWindow])
    func anAgentShownInAnotherWindowBringsThatWindowForward(_ disposition: AttachDisposition) async {
        let (host, coordinator) = make()
        await coordinator.attach(identity: worker, from: otherWindow, disposition: .content)

        await coordinator.attach(identity: worker, from: window, disposition: disposition)

        #expect(host.focused == [host.handles[0]])
        #expect(host.contentCalls.count == 1, "no second surface for the agent")
        #expect(host.windowCalls.isEmpty)
        #expect(host.discardedPlaceholders == [window], "the host closes it only if it is an untouched start screen")
    }

    @Test func anAgentAlreadyShownInThisWindowIsFocusedInPlace() async {
        let (host, coordinator) = make()
        await coordinator.attach(identity: worker, from: window, disposition: .content)

        await coordinator.attach(identity: worker, from: window, disposition: .content)

        #expect(host.focused == [host.handles[0]])
        #expect(host.contentCalls.count == 1)
        #expect(host.discardedPlaceholders.isEmpty, "its own window is never discarded")
    }

    @Test func thePaletteGoesToTheWindowShowingTheAgent() async {
        let (host, coordinator) = make()
        await coordinator.attach(identity: worker, from: otherWindow, disposition: .content)
        let router = makeRouter(coordinator)
        let request = LeoSurfaceRequest(origin: window, disposition: .content)
        router.begin(request)

        await router.choose(.agent(worker, placement: .newWindow), for: request)

        #expect(host.focused == [host.handles[0]])
        #expect(host.windowCalls.isEmpty)
    }

    @Test func anotherHostsAgentWithTheSameNameIsADifferentAgent() async {
        let (host, coordinator) = make()
        await coordinator.attach(identity: worker, from: otherWindow, disposition: .content)

        await coordinator.attach(identity: remoteWorker, from: window, disposition: .content)

        #expect(host.focused.isEmpty)
        #expect(host.contentCalls.count == 2)
    }

    @Test func aSplitStillAttachesItsOwnSurface() async {
        let (host, coordinator) = make()
        await coordinator.attach(identity: worker, from: window, disposition: .content)

        let split = LeoSurfaceRequest(origin: window, disposition: .split(.right), splitSourceSurface: UUID())
        _ = await coordinator.attach(identity: worker, request: split)

        #expect(host.splitCalls.count == 1, "B-058 decides splits")
        #expect(host.focused.isEmpty)
    }

    // MARK: New window (D-104)

    @Test func commandClickOpensANewWindowWhenTheAgentIsNotOnScreen() async {
        let (host, coordinator) = make()

        await coordinator.attach(identity: worker, from: window, disposition: .newWindow)

        #expect(host.windowCalls.count == 1)
        #expect(host.contentCalls.isEmpty)
        #expect(host.replacementConfirmations.isEmpty, "nothing is replaced")
    }

    @Test func commandReturnOpensTheChoiceInANewWindow() async {
        let (host, coordinator) = make()
        let router = makeRouter(coordinator)
        let request = LeoSurfaceRequest(origin: window, disposition: .content)
        router.begin(request)

        await router.choose(.agent(worker, placement: .newWindow), for: request)

        #expect(host.windowCalls.map(\.requestID) == [request.id], "same request, so its inherited config applies")
        #expect(host.contentCalls.isEmpty)
    }

    @Test func commandReturnOnASplitRequestStillSplits() async {
        let (host, coordinator) = make()
        let split = LeoSurfaceRequest(origin: window, disposition: .split(.right), splitSourceSurface: UUID())

        _ = await coordinator.attach(identity: worker, request: split, placement: .newWindow)

        #expect(host.splitCalls.count == 1, "no new-window hint there, so no new window either")
        #expect(host.windowCalls.isEmpty)
    }

    @Test func commandReturnIsTheNewWindowChoice() {
        let model = LeoAgentPaletteModel()
        model.update(
            snapshot: LeoSidebarSnapshot(rows: [row(worker)], connectivity: .connected, generation: 1),
            selectedHost: .local,
            hostState: .connected(socketPath: "/tmp/leo.sock")
        )

        #expect(model.confirm() == .agent(worker, placement: .requested))
        #expect(model.confirm(placement: .newWindow) == .agent(worker, placement: .newWindow))
        #expect(LeoAttachPlacement(modifierFlags: []) == .requested)
        #expect(LeoAttachPlacement(modifierFlags: [.shift]) == .requested)
        #expect(LeoAttachPlacement(modifierFlags: [.command]) == .newWindow)
    }

    @Test func theRouterPassesTheChoicesPlacementToAttach() async {
        var placements: [LeoAttachPlacement] = []
        let router = LeoNewSurfaceRouter(
            attach: { _, _, placement in
                placements.append(placement)
                return .success(())
            },
            openPlainShell: { _ in .success(()) },
            presentSpawn: { _, complete in complete(nil) }
        )
        let first = LeoSurfaceRequest(origin: window, disposition: .content)
        router.begin(first)
        await router.choose(.agent(worker), for: first)
        let second = LeoSurfaceRequest(origin: window, disposition: .content)
        router.begin(second)
        await router.choose(.agent(worker, placement: .newWindow), for: second)

        #expect(placements == [.requested, .newWindow])
    }

    @Test(arguments: [
        (LeoSurfaceDisposition.content, true),
        (.placeholder, true),
        (.window, true),
        (.split(.right), false),
        (.placeholder(surfaceID: UUID()), false),
    ])
    func whichRequestsFocusAnAgentAlreadyOnScreen(_ disposition: LeoSurfaceDisposition, _ focuses: Bool) {
        #expect(disposition.focusesAgentOnScreen == focuses)
    }

    // MARK: Replacing a running shell asks first

    @Test func onlyAContentRequestAsksBeforeReplacing() async {
        let (host, coordinator) = make()

        await coordinator.attach(identity: worker, from: window, disposition: .content)
        _ = await coordinator.attach(identity: other, request: LeoSurfaceRequest(origin: window, disposition: .placeholder))
        _ = await coordinator.attach(
            identity: other, request: LeoSurfaceRequest(origin: window, disposition: .split(.down), splitSourceSurface: UUID()))

        #expect(host.replacementConfirmations == [window])
    }

    @Test func keepingTheShellLeavesTheContentAreaAloneAndReportsNothing() async {
        let (host, coordinator, reported) = makeReporting()
        host.confirmsReplacement = false

        let result = await coordinator.attach(identity: worker, request: LeoSurfaceRequest(origin: window, disposition: .content))

        #expect(host.contentCalls.isEmpty)
        #expect((try? result.get()) == nil)
        if case .failure(let error) = result { #expect(error.isCancellation) }
        #expect(reported.errors.isEmpty, "the user's choice, not an error")
    }

    @Test func keepingTheShellCancelsAPlainShellToo() async {
        let (host, coordinator) = make()
        host.confirmsReplacement = false

        let result = await coordinator.openPlainShell(request: LeoSurfaceRequest(origin: window, disposition: .content))

        #expect(host.contentCalls.isEmpty)
        if case .failure(let error) = result { #expect(error.isCancellation) } else { Issue.record("expected a cancellation") }
    }

    @Test func aCancelledReplacementEndsThePaletteRequestQuietly() async {
        let (host, coordinator) = make()
        host.confirmsReplacement = false
        var failures: [LeoAttachError] = []
        var ended: [UUID] = []
        let router = makeRouter(coordinator, onFailure: { failures.append($1) }, onRequestEnded: { ended.append($0.id) })
        let request = LeoSurfaceRequest(origin: window, disposition: .content)
        router.begin(request)

        await router.choose(.agent(worker), for: request)

        #expect(failures.isEmpty, "no palette error for the user's own Cancel")
        #expect(ended == [request.id])
    }

    @Test(arguments: [
        ([LeoContentReplacement.Shown(isAgent: false, needsConfirmQuit: true)], true),
        ([.init(isAgent: false, needsConfirmQuit: false)], false),
        ([.init(isAgent: true, needsConfirmQuit: true)], false),
        ([.init(isAgent: true, needsConfirmQuit: true), .init(isAgent: false, needsConfirmQuit: true)], true),
        ([], false),
    ])
    func onlyARunningPlainShellNeedsConfirmation(_ shown: [LeoContentReplacement.Shown], _ asks: Bool) {
        #expect(LeoContentReplacement.needsConfirmation(shown) == asks)
    }

    // MARK: Sidebar clicks

    @Test func aPlainClickShowsTheRowInThisWindow() {
        let model = makeModel()
        var dispositions: [AttachDisposition] = []
        model.attachRequested = { dispositions.append($2) }

        model.rowClicked(row(worker), from: window)

        #expect(dispositions == [.content])
    }

    @Test func commandClickOpensANewWindowEvenWithTheAgentOnScreen() {
        let model = makeModel()
        var focusRequests: [LeoAgentRow.ID] = []
        var attaches: [(LeoAgentRow.ID, LeoWindowID, AttachDisposition)] = []
        model.focusExistingRequested = { row, _ in focusRequests.append(row.id) }
        model.attachRequested = { attaches.append(($0.id, $1, $2)) }
        model.receiveAttachLinks(LeoAttachLinkState(focused: nil, attachCounts: [id(worker): 1]))

        model.rowClicked(row(worker), modifierFlags: .command, from: window)

        #expect(focusRequests.isEmpty, "the coordinator focuses it (D-104)")
        #expect(attaches.map(\.2) == [.newWindow])
        #expect(attaches.first?.1 == window)
        #expect(model.selection == id(worker))
    }

    @Test func aCommandDoubleClicksSecondClickBringsItsWindowForward() {
        let model = makeModel()
        var dispositions: [AttachDisposition] = []
        model.attachRequested = { dispositions.append($2) }

        model.rowClicked(row(worker), modifierFlags: .command, clickCount: 1, from: window)
        model.rowClicked(row(worker), modifierFlags: .command, clickCount: 2, from: window)

        #expect(dispositions == [.newWindow, .content])
    }

    @Test func optionDoubleClickOpensANewWindow() {
        let model = makeModel()
        var dispositions: [AttachDisposition] = []
        model.attachRequested = { dispositions.append($2) }

        model.rowClicked(row(worker), modifierFlags: .option, clickCount: 1, from: window)
        model.rowClicked(row(worker), modifierFlags: .option, clickCount: 2, from: window)

        #expect(dispositions == [.newWindow])
    }

    @Test func theAttachMenuItemFollowsTheSameModifiers() {
        #expect(LeoAttachActivation.disposition(for: []) == .content)
        #expect(LeoAttachActivation.disposition(for: .option) == .newWindow)
    }

    // MARK: Helpers

    private func id(_ identity: LeoAgentIdentity) -> LeoAgentRow.ID { LeoAgentRow.ID(host: identity.host, name: identity.name) }

    private func row(_ identity: LeoAgentIdentity) -> LeoAgentRow {
        LeoAgentRow(host: identity.host, name: identity.name, template: nil, status: .running, activity: .idle, actionDetail: nil)
    }

    private func makeModel() -> LeoSidebarModel {
        LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: [row(worker)], connectivity: .connected, generation: 1))
    }

    @MainActor private final class Reported { var errors: [LeoAttachError] = [] }

    private func makeReporting() -> (FakeAttachContentHost, LeoAttachCoordinator, Reported) {
        let host = FakeAttachContentHost()
        let reported = Reported()
        let coordinator = LeoAttachCoordinator(
            host: host,
            executable: { "/leo" },
            remoteCommandBuilder: { "ssh box leo attach \($0.name)" },
            report: { reported.errors.append($0) },
            lifecycleEventHandled: { host.acknowledge($0) }
        )
        return (host, coordinator, reported)
    }

    private func make() -> (FakeAttachContentHost, LeoAttachCoordinator) {
        let (host, coordinator, _) = makeReporting()
        return (host, coordinator)
    }

    private func makeRouter(
        _ coordinator: LeoAttachCoordinator,
        onFailure: @escaping (LeoSurfaceRequest, LeoAttachError) -> Void = { _, _ in },
        onRequestEnded: @escaping (LeoSurfaceRequest) -> Void = { _ in }
    ) -> LeoNewSurfaceRouter {
        LeoNewSurfaceRouter(
            attach: { identity, request, placement in
                await coordinator.attach(identity: identity, request: request, placement: placement).map { _ in () }
            },
            openPlainShell: { request in await coordinator.openPlainShell(request: request).map { _ in () } },
            presentSpawn: { _, complete in complete(nil) },
            onFailure: onFailure,
            onRequestEnded: onRequestEnded
        )
    }
}
