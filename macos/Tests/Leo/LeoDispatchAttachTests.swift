import AppKit
import Foundation
import Testing

@testable import Ghostty

/// B-266: dispatch rows the daemon can attach to open in the content area.
/// Everything is gated on the `dispatch_attach` feature AND the dispatch's
/// own `attachable`; the attach machinery is faked at the host boundary.
struct LeoDispatchAttachDecodingTests {
    private func decode(_ json: String) throws -> LeoDispatch {
        try JSONDecoder().decode(LeoDispatch.self, from: Data(json.utf8))
    }

    @Test func attachableDecodesAndDefaultsToFalse() throws {
        #expect(try decode(#"{"id":"d1","status":"running","attachable":true}"#).attachable)
        #expect(try !decode(#"{"id":"d1","status":"running","attachable":false}"#).attachable)
        #expect(try !decode(#"{"id":"d1","status":"running"}"#).attachable, "an older daemon sends none")
        #expect(try !decode(#"{"id":"d1","status":"running","attachable":"yes"}"#).attachable, "a wrong type degrades, not drops")
    }

    @Test func theFeatureIsKnownByName() {
        #expect(LeoDaemonFeatures(["dispatch_attach"]).contains(.dispatchAttach))
        #expect(!LeoDaemonFeatures(["dispatch_tree"]).contains(.dispatchAttach))
    }
}

struct LeoDispatchAttachCommandTests {
    @Test func buildsALocalCommand() throws {
        let command = try LeoAttachCommand.build(executable: "/opt/leo", identity: .dispatch(host: .local, id: "d-1", title: nil))
        #expect(command == "env -u TMUX -u TMUX_PANE '/opt/leo' dispatch attach 'd-1'")
    }

    @Test func includesTheRemoteHost() throws {
        let command = try LeoAttachCommand.build(executable: "/leo", identity: .dispatch(host: .remote("build host"), id: "d-1", title: nil))
        #expect(command == "env -u TMUX -u TMUX_PANE '/leo' --host 'build host' dispatch attach 'd-1'")
    }

    @Test(arguments: ["", "-x", "--help", "bad\0id", "bad\nid", "bad\rid"])
    func refusesAnIDThatCouldBeAFlagOrBreakTheLine(_ id: String) {
        #expect(throws: LeoAttachCommandError.invalidDispatchID) {
            try LeoAttachCommand.build(executable: "/leo", identity: .dispatch(host: .local, id: id, title: nil))
        }
    }

    @Test func aDispatchNeverSharesAnAgentRowsIdentity() {
        #expect(LeoAgentIdentity.dispatch(host: .local, id: "d-1", title: "x") != LeoAgentIdentity(host: .local, name: "d-1"))
    }

    /// Uniqueness must not lean on the reserved `dispatch.` name form.
    @Test func anAgentNamedLikeADispatchIsNotThatDispatch() {
        let dispatch = LeoAgentIdentity.dispatch(host: .local, id: "d1", title: nil)
        let lookalike = LeoAgentIdentity(host: .local, name: "dispatch.d1")
        #expect(dispatch != lookalike)
        #expect(Set([dispatch, lookalike]).count == 2)
    }
}

@MainActor struct LeoDispatchAttachCoordinatorTests {
    private let origin = LeoWindowID()
    private let identity = LeoAgentIdentity.dispatch(host: .local, id: "d-1", title: "Reviewer")

    private func makeCoordinator(
        host: FakeAttachContentHost,
        remoteCommandBuilder: @escaping (LeoAgentIdentity) throws -> String = { _ in "remote" }
    ) -> LeoAttachCoordinator {
        LeoAttachCoordinator(
            host: host, executable: { "/leo" }, remoteCommandBuilder: remoteCommandBuilder, report: { _ in },
            lifecycleEventHandled: { host.acknowledge($0) }
        )
    }

    @Test func attachesInTheContentAreaTitledAfterTheDispatch() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        #expect(host.contentCalls.map(\.command) == ["env -u TMUX -u TMUX_PANE '/leo' dispatch attach 'd-1'"])
        #expect(host.agentNames.map(\.1) == ["Reviewer"])
    }

    @Test func aRemoteDispatchGoesThroughTheRemoteBuilder() async {
        let host = FakeAttachContentHost()
        var built: [LeoAgentIdentity] = []
        let coordinator = makeCoordinator(host: host) { built.append($0); return "ssh-attach" }
        let remote = LeoAgentIdentity.dispatch(host: .remote("work"), id: "d-9", title: nil)
        await coordinator.attach(identity: remote, from: origin, disposition: .content)
        #expect(built.map(\.dispatchID) == ["d-9"])
        #expect(host.contentCalls.map(\.command) == ["ssh-attach"])
    }

    @Test func aSecondOpenFocusesTheSameSurface() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        #expect(host.contentCalls.count == 1)
        #expect(host.focused == [host.handles[0]])
    }

    /// The CLI exits when the dispatch closes: no exited placeholder, the
    /// surface closes.
    @Test func whenTheDispatchEndsItsSurfaceClosesWithoutAPlaceholder() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        let handle = host.handles[0]
        await host.emitAndWait(.processExited(handle))
        #expect(host.closedTerminals == [handle])
        #expect(host.reborn.isEmpty)
        #expect(coordinator.inactiveHandleCount == 0)
        #expect(coordinator.identity(forSurface: handle.surfaceID) == nil)
    }

    /// `closeTerminal` leaves a surface hidden in the live pool: the exit
    /// cleanup must still let it go, not drop its identity and strand it.
    @Test func aPooledDispatchSurfaceIsLetGoWhenItsProcessExits() async {
        let host = FakeAttachContentHost()
        host.closeTerminalLeavesPooledSurfaces = true
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        let dispatchHandle = host.handles[0]
        await coordinator.attach(identity: .init(host: .local, name: "worker"), from: origin, disposition: .content)
        #expect(host.isHidden(dispatchHandle), "precondition: pooled")

        await host.emitAndWait(.processExited(dispatchHandle))

        #expect(!host.isOpen(dispatchHandle), "no exited dispatch lingers in a pooled split")
        #expect(host.reborn.isEmpty)
    }

    @Test func anAgentsExitStillLeavesItsPlaceholder() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: .init(host: .local, name: "worker"), from: origin, disposition: .content)
        await host.emitAndWait(.processExited(host.handles[0]))
        #expect(host.closedTerminals.isEmpty)
        #expect(host.reborn == [host.handles[0]])
    }
}

@MainActor struct LeoDispatchSelectionTests {
    private let alpha = LeoAgentRow(host: .local, name: "alpha", template: nil, status: .running, activity: .idle, actionDetail: nil)

    private func dispatch(_ id: String, attachable: Bool) -> LeoDispatch {
        LeoDispatch(id: id, name: "n-\(id)", status: "running", callerAgent: "alpha", attachable: attachable)
    }

    private func snapshot(
        _ dispatches: [LeoDispatch], features: [String] = ["dispatch_tree", "dispatch_attach"],
        connectivity: LeoConnectivity = .connected, generation: Int = 1
    ) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: [alpha], connectivity: connectivity, generation: generation,
            dispatchChildren: ["alpha": dispatches.map { LeoDispatchNode(dispatch: $0, depth: 0) }],
            features: LeoDaemonFeatures(features)
        )
    }

    private func model(_ snapshot: LeoSidebarSnapshot) -> LeoSidebarModel { LeoSidebarModel(snapshot: snapshot) }

    private func ref(_ id: String) -> LeoDispatchRef { LeoDispatchRef(host: .local, id: id) }

    @Test func onlyAnAttachableDispatchOfAnAdvertisingDaemonIsSelectable() {
        let both = model(snapshot([]))
        #expect(both.isDispatchSelectable(dispatch("d1", attachable: true)))
        #expect(!both.isDispatchSelectable(dispatch("d1", attachable: false)))
        let noFeature = model(snapshot([], features: ["dispatch_tree"]))
        #expect(!noFeature.isDispatchSelectable(dispatch("d1", attachable: true)))
        let disconnected = model(snapshot([], connectivity: .disconnected(reason: "gone", isRetrying: false)))
        #expect(!disconnected.isDispatchSelectable(dispatch("d1", attachable: true)))
    }

    @Test func selectingADispatchRoutesThroughTheSidebarSelection() {
        let model = model(snapshot([dispatch("d1", attachable: true)]))
        let terminals = LeoWindowTerminals()
        LeoSidebarSelection.select(.dispatch(ref("d1")), model: model, terminals: terminals)
        #expect(LeoSidebarSelection.current(model: model, terminals: terminals) == .dispatch(ref("d1")))
        #expect(model.selection == alpha.id, "its agent stays selected beneath it")

        LeoSidebarSelection.select(.agent(alpha.id), model: model, terminals: terminals)
        #expect(LeoSidebarSelection.current(model: model, terminals: terminals) == .agent(alpha.id))
    }

    @Test func aNonAttachableDispatchCannotBeSelected() {
        let model = model(snapshot([dispatch("d1", attachable: false)]))
        let terminals = LeoWindowTerminals()
        LeoSidebarSelection.select(.dispatch(ref("d1")), model: model, terminals: terminals)
        #expect(model.selectedDispatch == nil)
        #expect(LeoSidebarSelection.current(model: model, terminals: terminals) == nil)
    }

    @Test func aClickOpensItInTheClickedWindow() {
        let model = model(snapshot([dispatch("d1", attachable: true)]))
        var requests: [(LeoAgentIdentity, LeoWindowID, AttachDisposition)] = []
        model.dispatchAttachRequested = { requests.append(($0, $1, $2)) }
        let window = LeoWindowID()

        model.dispatchClicked(ref("d1"), from: window)
        model.dispatchClicked(ref("d1"), modifierFlags: .command, from: window)

        #expect(requests.map(\.0.dispatchID) == ["d1", "d1"])
        #expect(requests.map(\.0.title) == ["n-d1", "n-d1"])
        #expect(requests.map(\.1) == [window, window])
        #expect(requests.map(\.2) == [.content, .newWindow])
    }

    @Test func returnOpensTheSelectedDispatchNotItsAgent() {
        let model = model(snapshot([dispatch("d1", attachable: true)]))
        var dispatchOpens = 0
        var agentOpens = 0
        model.dispatchAttachRequested = { _, _, _ in dispatchOpens += 1 }
        model.attachRequested = { _, _, _ in agentOpens += 1 }
        model.userSelectedDispatch(ref("d1"))
        model.activateSelection(from: LeoWindowID())
        #expect(dispatchOpens == 1)
        #expect(agentOpens == 0)
    }

    @Test func aClickOnAnInertDispatchOpensNothing() {
        let model = model(snapshot([dispatch("d1", attachable: false)]))
        var opens = 0
        model.dispatchAttachRequested = { _, _, _ in opens += 1 }
        model.dispatchClicked(ref("d1"), from: LeoWindowID())
        #expect(opens == 0)
    }

    @Test func whenTheDispatchEndsSelectionFallsBackToItsAgent() {
        let model = model(snapshot([dispatch("d1", attachable: true)]))
        let terminals = LeoWindowTerminals()
        model.userSelectedDispatch(ref("d1"))
        model.receive(snapshot([], generation: 2))
        #expect(model.selectedDispatch == nil)
        #expect(LeoSidebarSelection.current(model: model, terminals: terminals) == .agent(alpha.id))
    }

    @Test func clickingTheAgentRowDropsTheDispatchSelection() {
        let model = model(snapshot([dispatch("d1", attachable: true)]))
        model.userSelectedDispatch(ref("d1"))
        model.rowClicked(alpha)
        #expect(model.selectedDispatch == nil)
        // ... and it stays dropped if the agent is selected again later.
        #expect(model.dispatchSelection == nil)
    }

    /// A selection that fell back stays fallen back: the dispatch coming
    /// back on a reconnect must not pull the selection onto it again.
    @Test func aDispatchSelectionThatFellBackStaysClearedAcrossAReconnect() {
        let live = dispatch("d1", attachable: true)
        let model = model(snapshot([live]))
        model.userSelectedDispatch(ref("d1"))
        model.receive(snapshot([live], features: [], connectivity: .disconnected(reason: "gone", isRetrying: false), generation: 2))
        model.receive(snapshot([live], generation: 3))
        #expect(model.selectedDispatch == nil)
        #expect(LeoSidebarSelection.current(model: model, terminals: LeoWindowTerminals()) == .agent(alpha.id))
    }

    @Test func focusingAnotherAgentThenTheParentDoesNotReviveTheDispatch() {
        let beta = LeoAgentRow(host: .local, name: "beta", template: nil, status: .running, activity: .idle, actionDetail: nil)
        let live = LeoDispatchNode(dispatch: dispatch("d1", attachable: true), depth: 0)
        let model = model(LeoSidebarSnapshot(
            rows: [alpha, beta], connectivity: .connected, generation: 1,
            dispatchChildren: ["alpha": [live]], features: LeoDaemonFeatures(["dispatch_tree", "dispatch_attach"])
        ))
        model.userSelectedDispatch(ref("d1"))
        model.selection = beta.id
        model.selection = alpha.id
        #expect(model.selectedDispatch == nil)
    }

    /// Focus moving to another open dispatch's surface selects that row.
    @Test func focusingAnotherDispatchSurfaceMovesTheSelectionToIt() {
        let model = model(snapshot([dispatch("d1", attachable: true), dispatch("d2", attachable: true)]))
        model.userSelectedDispatch(ref("d1"))
        let d2 = LeoAgentIdentity.dispatch(host: .local, id: "d2", title: nil)
        let links = LeoAttachLinkState(
            focused: d2, handlesByIdentity: [d2: [AttachmentHandle(surfaceID: UUID(), windowID: LeoWindowID())]], inactive: [], focusReport: 5
        )
        #expect(links.focused == nil, "a dispatch surface is no agent row")
        #expect(links.focusedDispatch == ref("d2"))
        #expect(links.attachCounts.isEmpty)
        model.receiveAttachLinks(links)
        #expect(model.selectedDispatch == ref("d2"))
    }

    @Test func aDisconnectMakesTheSelectedDispatchInertAgain() {
        let model = model(snapshot([dispatch("d1", attachable: true)]))
        model.userSelectedDispatch(ref("d1"))
        model.receive(snapshot([dispatch("d1", attachable: true)], features: [], connectivity: .disconnected(reason: "gone", isRetrying: false), generation: 2))
        #expect(model.selectedDispatch == nil)
    }
}
