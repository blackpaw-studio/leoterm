import Foundation
import Testing

@testable import Ghostty

/// B-272: leo >= 0.42 (`dispatch_placement_live`) moves a dispatch viewer
/// between the caller's session and `leo-dispatch` while it runs. The
/// daemon reports the move as a `dispatch_changed` for the same dispatch
/// (`attachable` flips, the pane id stays); the row must follow it.
@MainActor struct LeoDispatchPlacementLiveTests {
    private let alpha = LeoAgentRow(host: .local, name: "alpha", template: nil, status: .running, activity: .idle, actionDetail: nil)
    private let live = ["dispatch_tree", "dispatch_attach", "dispatch_placement_live"]

    /// A viewer in the background: alone in its own window, attachable.
    private var background: LeoDispatch { dispatch(attachable: true, kind: .background) }
    /// A viewer left in the caller's session: not attachable, pane reported.
    private var visible: LeoDispatch { dispatch(attachable: false, kind: .split) }

    private func dispatch(attachable: Bool, kind: LeoDispatchViewerKind?, pane: String? = "%41") -> LeoDispatch {
        LeoDispatch(id: "d1", name: "fixer", status: "running", callerAgent: "alpha", attachable: attachable, tmuxTarget: pane, viewerKind: kind)
    }

    private func snapshot(_ dispatch: LeoDispatch, features: [String], generation: Int) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: [alpha], connectivity: .connected, generation: generation,
            dispatchChildren: ["alpha": [LeoDispatchNode(dispatch: dispatch, depth: 0)]],
            features: LeoDaemonFeatures(features)
        )
    }

    private let ref = LeoDispatchRef(host: .local, id: "d1")

    @Test func aClickAfterAMoveTargetsWhereTheViewerNowIs() {
        let model = LeoSidebarModel(snapshot: snapshot(background, features: live, generation: 1))
        var focuses: [String] = []
        var attaches: [String?] = []
        model.dispatchPaneFocusRequested = { _, pane, _ in focuses.append(pane) }
        model.dispatchAttachRequested = { identity, _, _ in attaches.append(identity.dispatchID) }
        model.attachRequested = { _, _, _ in }

        model.dispatchClicked(ref, from: LeoWindowID())
        #expect(attaches == ["d1"], "in the background it attaches")
        #expect(focuses.isEmpty)

        model.receive(snapshot(visible, features: live, generation: 2))
        model.dispatchClicked(ref, from: LeoWindowID())
        #expect(focuses == ["%41"], "moved into the caller's session it focuses that pane")
        #expect(attaches == ["d1"], "and does not attach")

        model.receive(snapshot(background, features: live, generation: 3))
        model.dispatchClicked(ref, from: LeoWindowID())
        #expect(attaches == ["d1", "d1"], "back in the background it attaches again")
        #expect(focuses == ["%41"])
    }

    @Test func aSelectedDispatchThatMovesIntoItsCallersSessionFallsBackToItsAgent() {
        let model = LeoSidebarModel(snapshot: snapshot(background, features: live, generation: 1))
        model.userSelectedDispatch(ref)
        #expect(model.selectedDispatch == ref)

        model.receive(snapshot(visible, features: live, generation: 2))
        #expect(model.selectedDispatch == nil)
        #expect(model.selection == alpha.id)

        model.receive(snapshot(background, features: live, generation: 3))
        #expect(model.isDispatchSelectable(background), "selectable again")
        #expect(model.selectedDispatch == nil, "but a fallen-back selection is not revived")
    }

    @Test func aBackgroundViewerTheDaemonCantAttachIsInertUnderLivePlacement() {
        let stuck = dispatch(attachable: false, kind: .background)
        let model = LeoSidebarModel(snapshot: snapshot(stuck, features: live, generation: 1))
        var requests = 0
        model.dispatchPaneFocusRequested = { _, _, _ in requests += 1 }
        model.dispatchAttachRequested = { _, _, _ in requests += 1 }
        model.attachRequested = { _, _, _ in requests += 1 }

        #expect(!model.isDispatchClickable(stuck), "its pane is in leo-dispatch, not the caller's session")
        model.dispatchClicked(ref, from: LeoWindowID())
        #expect(requests == 0)
    }

    @Test func withoutLivePlacementViewerKindIsIgnored() {
        let reported = dispatch(attachable: false, kind: .background)
        let model = LeoSidebarModel(snapshot: snapshot(reported, features: ["dispatch_tree", "dispatch_attach"], generation: 1))
        var focuses: [String] = []
        model.dispatchPaneFocusRequested = { _, pane, _ in focuses.append(pane) }
        model.attachRequested = { _, _, _ in }

        #expect(model.isDispatchClickable(reported))
        model.dispatchClicked(ref, from: LeoWindowID())
        #expect(focuses == ["%41"], "as B-271 has it")
    }

    @Test func aKindOtherThanBackgroundKeepsTheCallersPaneClickable() {
        for kind: LeoDispatchViewerKind? in [.split, .hidden, .window, nil] {
            let reported = dispatch(attachable: false, kind: kind)
            let model = LeoSidebarModel(snapshot: snapshot(reported, features: live, generation: 1))
            #expect(model.isDispatchClickable(reported), "\(String(describing: kind))")
        }
    }
}
