import AppKit
import Foundation
import Testing

@testable import Ghostty

/// B-047: one tab per agent. Every entry point (sidebar row click, palette
/// choose on ⌘T or the start screen's Choose Agent…) goes to the agent's
/// open tab through the one B-006 lookup (`LeoAttachCoordinator`, keyed by
/// host + name); ⌘ forces a new tab.
@MainActor struct LeoOneTabPerAgentTests {
    private let local = LeoAgentIdentity(host: .local, name: "worker")
    private let remote = LeoAgentIdentity(host: .remote("box"), name: "worker")
    private let origin = LeoWindowID()

    // MARK: Palette choose (coordinator)

    @Test func choosingAnAgentWithATabInAnotherWindowFocusesThatTab() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: local, from: LeoWindowID(), disposition: .reuseOrTab)

        let result = await coordinator.attach(identity: local, request: LeoSurfaceRequest(origin: origin, disposition: .tab))

        #expect(host.tabCalls.count == 1, "no second tab")
        #expect(host.focused == [host.handles[0]])
        #expect(host.handles[0].windowID != origin, "the tab lives in another window")
        #expect((try? result.get()) == host.handles[0])
    }

    @Test func chooseAgentOnTheStartScreenFocusesTheOpenTabAndClosesTheEmptyOne() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: local, from: LeoWindowID(), disposition: .reuseOrTab)

        _ = await coordinator.attach(identity: local, request: LeoSurfaceRequest(origin: origin, disposition: .placeholder))

        #expect(host.placeholderCalls.isEmpty)
        #expect(host.focused == [host.handles[0]])
        #expect(host.discardedPlaceholders == [origin])
    }

    @Test func chooseAgentWithoutAnOpenTabFillsTheStartScreen() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)

        _ = await coordinator.attach(identity: local, request: LeoSurfaceRequest(origin: origin, disposition: .placeholder))

        #expect(host.placeholderCalls.count == 1)
        #expect(host.focused.isEmpty)
        #expect(host.discardedPlaceholders.isEmpty)
    }

    @Test func aPaneLeftByAnExitedAttachIsFilledNotSkipped() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: local, from: LeoWindowID(), disposition: .reuseOrTab)

        let leaf = LeoSurfaceRequest(origin: origin, disposition: .placeholder(surfaceID: UUID()))
        _ = await coordinator.attach(identity: local, request: leaf)

        #expect(host.placeholderCalls.count == 1, "a pane in an existing tab is like a split: it always attaches")
        #expect(host.discardedPlaceholders.isEmpty)
    }

    @Test(arguments: [LeoSurfaceDisposition.tab, .placeholder])
    func commandReturnForcesANewTab(_ disposition: LeoSurfaceDisposition) async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: local, from: LeoWindowID(), disposition: .reuseOrTab)

        _ = await coordinator.attach(identity: local, request: LeoSurfaceRequest(origin: origin, disposition: disposition), reuse: .alwaysNew)

        #expect(host.tabCalls.count + host.placeholderCalls.count == 2)
        #expect(host.focused.isEmpty)
        #expect(host.discardedPlaceholders.isEmpty)
    }

    @Test func anotherHostsAgentWithTheSameNameNeverMatches() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: local, from: LeoWindowID(), disposition: .reuseOrTab)

        _ = await coordinator.attach(identity: remote, request: LeoSurfaceRequest(origin: origin, disposition: .tab))

        #expect(host.tabCalls.count == 2)
        #expect(host.focused.isEmpty)
    }

    @Test func splitStillAttachesANewSplit() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: local, from: LeoWindowID(), disposition: .reuseOrTab)

        let split = LeoSurfaceRequest(origin: origin, disposition: .split(.right), splitSourceSurface: UUID())
        _ = await coordinator.attach(identity: local, request: split)

        #expect(host.splitCalls.count == 1)
        #expect(host.focused.isEmpty)
    }

    @Test func newTabDispositionAlwaysOpensATab() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: local, from: origin, disposition: .reuseOrTab)

        await coordinator.attach(identity: local, from: origin, disposition: .newTab)

        #expect(host.tabCalls.count == 2)
        #expect(host.focused.isEmpty)
    }

    // MARK: Palette choose (router + model)

    @Test func paletteReturnGoesToTheOpenTabAndCommandReturnForcesANewOne() {
        let model = LeoAgentPaletteModel()
        model.update(
            snapshot: LeoSidebarSnapshot(rows: [row(local)], connectivity: .connected, generation: 1),
            selectedHost: .local,
            hostState: .connected(socketPath: "/tmp/leo.sock")
        )

        #expect(model.confirm() == .agent(local, reuse: .focusExisting))
        #expect(model.confirm(reuse: .alwaysNew) == .agent(local, reuse: .alwaysNew))
    }

    @Test func commandReturnIsTheForcedChoice() {
        #expect(LeoAttachReuse(modifierFlags: []) == .focusExisting)
        #expect(LeoAttachReuse(modifierFlags: [.shift]) == .focusExisting)
        #expect(LeoAttachReuse(modifierFlags: [.command]) == .alwaysNew)
        #expect(LeoAgentPaletteFieldCommand.isForcedSubmit(keyCode: 36, modifierFlags: [.command]))
        #expect(LeoAgentPaletteFieldCommand.isForcedSubmit(keyCode: 76, modifierFlags: [.command]), "keypad Enter")
        #expect(!LeoAgentPaletteFieldCommand.isForcedSubmit(keyCode: 36, modifierFlags: []))
        #expect(!LeoAgentPaletteFieldCommand.isForcedSubmit(keyCode: 0, modifierFlags: [.command]))
    }

    @Test func theRouterPassesTheChoicesReuseToAttach() async {
        var reuses: [LeoAttachReuse] = []
        let router = LeoNewSurfaceRouter(
            attach: { _, _, reuse in
                reuses.append(reuse)
                return .success(())
            },
            openPlainShell: { _ in .success(()) },
            presentSpawn: { _, complete in complete(nil) }
        )
        let first = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(first)
        await router.choose(.agent(local), for: first)
        let second = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(second)
        await router.choose(.agent(local, reuse: .alwaysNew), for: second)

        #expect(reuses == [.focusExisting, .alwaysNew])
    }

    // MARK: Sidebar row click

    @Test func commandClickOpensANewTabEvenWithALiveOne() {
        let model = makeModel()
        var focusRequests: [LeoAgentRow.ID] = []
        var attaches: [(LeoAgentRow.ID, LeoWindowID, AttachDisposition)] = []
        model.focusExistingRequested = { row, _ in focusRequests.append(row.id) }
        model.attachRequested = { attaches.append(($0.id, $1, $2)) }
        model.receiveAttachLinks(LeoAttachLinkState(focused: nil, tabCounts: [id(local): 1]))

        model.rowClicked(row(local), modifierFlags: .command, from: origin)

        #expect(focusRequests.isEmpty)
        #expect(attaches.map(\.0) == [id(local)])
        #expect(attaches.first?.1 == origin)
        #expect(attaches.first?.2 == .newTab)
        #expect(model.selection == id(local))
    }

    @Test func onlyTheFirstClickOfACommandDoubleClickOpensATab() {
        let model = makeModel()
        var dispositions: [AttachDisposition] = []
        model.attachRequested = { dispositions.append($2) }

        model.rowClicked(row(local), modifierFlags: .command, clickCount: 1, from: origin)
        model.rowClicked(row(local), modifierFlags: .command, clickCount: 2, from: origin)

        #expect(dispositions == [.newTab, .reuseOrTab], "the second click brings that new tab forward (D-093)")
    }

    @Test func commandClickIsInertWhileDisconnected() {
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(
            rows: [row(local)], connectivity: .disconnected(reason: "gone", isRetrying: false), generation: 1))
        var attaches = 0
        model.attachRequested = { _, _, _ in attaches += 1 }

        model.rowClicked(row(local), modifierFlags: .command, from: origin)

        #expect(attaches == 0)
    }

    // MARK: Helpers

    private func id(_ identity: LeoAgentIdentity) -> LeoAgentRow.ID { LeoAgentRow.ID(host: identity.host, name: identity.name) }

    private func row(_ identity: LeoAgentIdentity) -> LeoAgentRow {
        LeoAgentRow(host: identity.host, name: identity.name, template: nil, status: .running, activity: .idle, actionDetail: nil)
    }

    private func makeModel() -> LeoSidebarModel {
        LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: [row(local)], connectivity: .connected, generation: 1))
    }

    private func makeCoordinator(host: FakeAttachTabHost) -> LeoAttachCoordinator {
        LeoAttachCoordinator(
            host: host,
            executable: { "/leo" },
            remoteCommandBuilder: { "ssh box leo attach \($0.name)" },
            report: { _ in },
            lifecycleEventHandled: { host.acknowledge($0) }
        )
    }
}
