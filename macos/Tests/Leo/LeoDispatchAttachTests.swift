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

struct AttachExitReportTests {
    @Test func theDetailIsTheLastNonBlankLine() {
        let report = AttachExitReport(code: 1, screenText: "\n  starting\nleo: no such dispatch \u{1B}[31mx\u{7}\n\n   \n")
        #expect(report.detail == "leo: no such dispatch [31mx")
    }

    @Test func aBlankScreenHasNoDetail() {
        #expect(AttachExitReport(code: 1, screenText: " \n\n").detail == nil)
        #expect(AttachExitReport(code: 1, screenText: "").detail == nil)
    }

    @Test func aLongLineIsCut() {
        let report = AttachExitReport(code: 1, screenText: String(repeating: "x", count: 500))
        #expect(report.detail?.count == AttachExitReport.maxDetailLength)
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

    /// A pooled split keeps its whole tree hidden: the exited dispatch
    /// leaves it alone, not taking a live agent (or shell) beside it along.
    @Test func aPooledDispatchExitLeavesTheLiveAgentBesideItInItsSplit() async {
        let host = FakeAttachContentHost()
        host.closeTerminalLeavesPooledSurfaces = true
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        let dispatchHandle = host.handles[0]
        await coordinator.attach(identity: .init(host: .local, name: "worker"), from: origin, disposition: .content)
        let sibling = AttachmentHandle(surfaceID: UUID(), windowID: dispatchHandle.windowID)
        host.openHandles.insert(sibling)
        host.pooledSplitMates[dispatchHandle] = [sibling]
        #expect(host.isHidden(dispatchHandle), "precondition: pooled")

        await host.emitAndWait(.processExited(dispatchHandle))

        #expect(!host.isOpen(dispatchHandle))
        #expect(host.isOpen(sibling), "the live surface beside it survives")
    }

    @Test func aDispatchSurfaceIsMarkedAsWatchedButAnAgentsIsNot() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: .init(host: .local, name: "worker"), from: origin, disposition: .content)
        #expect(host.watching.isEmpty)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        #expect(host.watching == [host.handles[1]])
    }

    @Test func aFailedAttachShowsABriefErrorAndLeavesNoSurface() async {
        let host = FakeAttachContentHost()
        var errors: [LeoAttachError] = []
        let coordinator = LeoAttachCoordinator(
            host: host, executable: { "/leo" }, report: { errors.append($0) }, lifecycleEventHandled: { host.acknowledge($0) }
        )
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        let handle = host.handles[0]
        host.exitReports[handle] = AttachExitReport(code: 1, detail: "leo: dispatch d-1 is not attachable")

        await host.emitAndWait(.processExited(handle))

        #expect(errors.map(\.message) == ["leo: dispatch d-1 is not attachable"])
        #expect(errors.first?.identity == identity)
        #expect(host.closedTerminals == [handle], "no zombie surface")
        #expect(host.reborn.isEmpty)
    }

    @Test func aFailureWithNoLineSaysItsExitCode() async {
        let host = FakeAttachContentHost()
        var errors: [LeoAttachError] = []
        let coordinator = LeoAttachCoordinator(
            host: host, executable: { "/leo" }, report: { errors.append($0) }, lifecycleEventHandled: { host.acknowledge($0) }
        )
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        host.exitReports[host.handles[0]] = AttachExitReport(code: 3, detail: nil)
        await host.emitAndWait(.processExited(host.handles[0]))
        #expect(errors.map(\.message) == ["Dispatch attach exited with code 3"])
    }

    @Test func aCleanExitReportsNothing() async {
        let host = FakeAttachContentHost()
        var errors: [LeoAttachError] = []
        let coordinator = LeoAttachCoordinator(
            host: host, executable: { "/leo" }, report: { errors.append($0) }, lifecycleEventHandled: { host.acknowledge($0) }
        )
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        host.exitReports[host.handles[0]] = AttachExitReport(code: 0, detail: "Detached")
        await host.emitAndWait(.processExited(host.handles[0]))
        #expect(errors.isEmpty)
        #expect(host.closedTerminals == [host.handles[0]])
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

    // MARK: nested dispatches

    private func nested(_ entries: [(String, Int, Bool)], generation: Int = 1) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: [alpha], connectivity: .connected, generation: generation,
            dispatchChildren: ["alpha": entries.map { LeoDispatchNode(dispatch: dispatch($0.0, attachable: $0.2), depth: $0.1) }],
            features: LeoDaemonFeatures(["dispatch_tree", "dispatch_attach"])
        )
    }

    private let chain = [("d1", 0, true), ("d2", 1, true), ("d3", 2, true)]

    @Test func aNestedDispatchIsSelectableAtAnyDepth() {
        let model = model(nested(chain))
        model.userSelectedDispatch(ref("d3"))
        #expect(model.selectedDispatch == ref("d3"))
    }

    @Test func whenASelectedNestedDispatchEndsSelectionFallsBackToTheNearestSurvivingAncestor() {
        let model = model(nested(chain))
        model.userSelectedDispatch(ref("d3"))
        model.receive(nested([("d1", 0, true), ("d2", 1, true)], generation: 2))
        #expect(model.selectedDispatch == ref("d2"))

        model.receive(nested([("d1", 0, true)], generation: 3))
        #expect(model.selectedDispatch == ref("d1"))

        model.receive(nested([], generation: 4))
        #expect(model.selectedDispatch == nil)
        #expect(LeoSidebarSelection.current(model: model, terminals: LeoWindowTerminals()) == .agent(alpha.id))
    }

    @Test func theFallbackSkipsAnAncestorThatIsNoLongerOrNotAttachable() {
        let model = model(nested(chain))
        model.userSelectedDispatch(ref("d3"))
        model.receive(nested([("d1", 0, true), ("d2", 1, false)], generation: 2))
        #expect(model.selectedDispatch == ref("d1"))
    }

    @Test func theFallbackSurvivesAnAncestorEndingFirst() {
        let model = model(nested(chain))
        model.userSelectedDispatch(ref("d3"))
        // d2 ends first: d3 re-parents under d1 and stays selected ...
        model.receive(nested([("d1", 0, true), ("d3", 1, true)], generation: 2))
        #expect(model.selectedDispatch == ref("d3"))
        // ... then d3 ends: the nearest surviving ancestor is d1.
        model.receive(nested([("d1", 0, true)], generation: 3))
        #expect(model.selectedDispatch == ref("d1"))
    }

    @Test func collapsingADispatchHidesItsDescendantsAndTheStateIsPerID() {
        let model = model(nested([("d1", 0, true), ("d2", 1, true), ("d3", 2, true), ("d4", 0, true)]))
        func shown() -> [String] { model.visibleDispatchRows(for: alpha).map(\.id) }
        #expect(model.visibleDispatchRows(for: alpha).map(\.hasChildren) == [true, true, false, false])
        #expect(shown() == ["d1", "d2", "d3", "d4"])

        model.toggleDispatchCollapsed(ref("d2"))
        #expect(shown() == ["d1", "d2", "d4"])
        #expect(model.visibleDispatchRows(for: alpha).map(\.isCollapsed) == [false, true, false])

        model.toggleDispatchCollapsed(ref("d1"))
        #expect(shown() == ["d1", "d4"])

        model.toggleDispatchCollapsed(ref("d1"))
        #expect(shown() == ["d1", "d2", "d4"], "d2 is still collapsed on its own")

        model.toggleDispatchCollapsed(ref("d2"))
        #expect(shown() == ["d1", "d2", "d3", "d4"])
    }

    @Test func aDisconnectMakesTheSelectedDispatchInertAgain() {
        let model = model(snapshot([dispatch("d1", attachable: true)]))
        model.userSelectedDispatch(ref("d1"))
        model.receive(snapshot([dispatch("d1", attachable: true)], features: [], connectivity: .disconnected(reason: "gone", isRetrying: false), generation: 2))
        #expect(model.selectedDispatch == nil)
    }
}
