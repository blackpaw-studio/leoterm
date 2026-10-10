import AppKit

/// The dispatch a selection names, with the agent row it sits under.
struct LeoDispatchSelection: Equatable, Sendable {
    let ref: LeoDispatchRef
    let parent: LeoAgentRow.ID
    /// The dispatches above it, nearest first, as of the last snapshot:
    /// where selection falls back to when it ends.
    let ancestors: [LeoDispatchRef]
}

/// B-266: dispatch rows the daemon can attach to are selectable, and open
/// in the content area like an agent row. Gated on the `dispatch_attach`
/// feature AND the dispatch's own `attachable`; anything else keeps the
/// informational, inert row.
extension LeoSidebarModel {
    /// Whether `dispatch` may be selected and opened: connected, the
    /// daemon advertised `dispatch_attach`, and it says this one is
    /// attachable.
    func isDispatchSelectable(_ dispatch: LeoDispatch) -> Bool {
        !isDisconnected && daemonFeatures.contains(.dispatchAttach) && dispatch.attachable
    }

    /// Whether a click on `dispatch`'s row does anything: it is
    /// selectable, or (B-271) the daemon can't attach to it but reported
    /// the pane its viewer sits in, in its caller's own tmux session.
    /// Such a row is clicked, never selected.
    func isDispatchClickable(_ dispatch: LeoDispatch) -> Bool {
        isDispatchSelectable(dispatch) || viewerPane(dispatch) != nil
    }

    /// The reported viewer pane of a live dispatch the daemon can't attach
    /// to, under the same gate as attaching (connected, `dispatch_attach`).
    /// B-272: a daemon with live placement that says the viewer sits in the
    /// background reports a pane in `leo-dispatch`, not the caller's
    /// session, so there is nothing here to bring forward.
    private func viewerPane(_ dispatch: LeoDispatch) -> String? {
        guard !isDisconnected, daemonFeatures.contains(.dispatchAttach), !dispatch.attachable, dispatch.isLive else {
            return nil
        }
        if daemonFeatures.contains(.dispatchPlacementLive), dispatch.viewerKind == .background { return nil }
        return dispatch.tmuxTarget
    }

    /// The agent row a non-attachable dispatch sits under, with the pane
    /// its viewer was reported in.
    func callerPaneTarget(_ ref: LeoDispatchRef) -> (row: LeoAgentRow, pane: String)? {
        for row in snapshot.rows where row.host == ref.host {
            if let node = dispatchChildren(for: row).first(where: { $0.id == ref.id }), let pane = viewerPane(node.dispatch) {
                return (row, pane)
            }
        }
        return nil
    }

    /// The selected dispatch, while it still lives under its parent row
    /// and is still attachable and that parent is still the selection.
    /// Once it ends, this is nil and the parent agent is what is selected.
    var selectedDispatch: LeoDispatchRef? {
        guard let selected = dispatchSelection, selected.parent == selection,
              dispatchTarget(selected.ref) != nil else { return nil }
        return selected.ref
    }

    /// After each snapshot. A valid dispatch selection refreshes the
    /// ancestors it would fall back to. One that is no longer valid (it
    /// ended, went inert, or the connection dropped) falls back to its
    /// nearest surviving, attachable ancestor dispatch, else to its agent,
    /// and is forgotten there, so it can't come back with the dispatch.
    func reconcileDispatchSelection() {
        guard let selected = dispatchSelection else { return }
        if selectedDispatch != nil {
            guard let target = dispatchTarget(selected.ref) else { return }
            dispatchSelection = makeSelection(selected.ref, under: target.row)
            return
        }
        guard selected.parent == selection,
              let heir = selected.ancestors.compactMap({ ref in dispatchTarget(ref).map { (ref, $0.row) } }).first else {
            dispatchSelection = nil
            return
        }
        dispatchSelection = makeSelection(heir.0, under: heir.1)
    }

    /// Collapsing a dispatch whose descendant is selected hides the
    /// selection, so (as in Finder or Xcode) the collapsed node takes it --
    /// or, if that one can't be selected, the nearest selectable dispatch
    /// above it, else the agent. Selection only: nothing is opened.
    func moveSelectionOutOfCollapsed(_ collapsed: LeoDispatchRef) {
        guard let selected = dispatchSelection, selected.ancestors.contains(collapsed) else { return }
        let above = selected.ancestors.drop { $0 != collapsed }
        guard let heir = above.compactMap({ ref in dispatchTarget(ref).map { (ref, $0.row) } }).first else {
            dispatchSelection = nil
            return
        }
        dispatchSelection = makeSelection(heir.0, under: heir.1)
    }

    private func makeSelection(_ ref: LeoDispatchRef, under row: LeoAgentRow) -> LeoDispatchSelection {
        LeoDispatchSelection(ref: ref, parent: row.id, ancestors: ancestors(of: ref, under: row))
    }

    /// The dispatches above `ref` in `row`'s nesting, nearest first. The
    /// nodes are depth first, so walking back and taking each shallower
    /// node finds them.
    private func ancestors(of ref: LeoDispatchRef, under row: LeoAgentRow) -> [LeoDispatchRef] {
        let nodes = dispatchChildren(for: row)
        guard let index = nodes.firstIndex(where: { $0.id == ref.id }) else { return [] }
        var depth = nodes[index].depth
        var found: [LeoDispatchRef] = []
        for node in nodes[..<index].reversed() where node.depth < depth {
            found.append(LeoDispatchRef(host: ref.host, id: node.id))
            depth = node.depth
        }
        return found
    }

    /// Selects an agent row and drops any dispatch selection under it.
    func selectAgentRow(_ id: LeoAgentRow.ID) {
        selection = id
        dispatchSelection = nil
    }

    /// The list's own selection change onto a dispatch row: selects it
    /// (and its parent agent, which stays selected once it ends).
    func userSelectedDispatch(_ ref: LeoDispatchRef) {
        guard let target = dispatchTarget(ref) else { return }
        selection = target.row.id
        dispatchSelection = makeSelection(ref, under: target.row)
        fenceInFlightFocusReports()
    }

    /// Focus moved onto an open dispatch's surface: its row is selected,
    /// when it still can be (the focus report is not a user choice, so no
    /// fence).
    func selectFocusedDispatch(_ ref: LeoDispatchRef) {
        guard let target = dispatchTarget(ref) else { return }
        selection = target.row.id
        dispatchSelection = makeSelection(ref, under: target.row)
    }

    /// A click on a dispatch row: it selects, and a click opens it where
    /// an agent row's would (⌘ in a new window, ⌥-double-click likewise).
    /// A dispatch viewed in its caller's session (B-271) instead brings
    /// that pane's window forward, then clicks through to the caller.
    func dispatchClicked(
        _ ref: LeoDispatchRef,
        modifierFlags: NSEvent.ModifierFlags = [],
        clickCount: Int = 1,
        from origin: LeoWindowID? = nil
    ) {
        if let viewed = callerPaneTarget(ref) {
            dispatchPaneFocusRequested(ref.host, viewed.pane, viewed.row.id)
            rowClicked(viewed.row, modifierFlags: modifierFlags, clickCount: clickCount, from: origin)
            return
        }
        userSelectedDispatch(ref)
        guard let origin, selectedDispatch == ref else { return }
        switch (clickCount, modifierFlags.contains(.command), modifierFlags.contains(.option)) {
        case (1, true, _): requestDispatchAttach(ref, from: origin, disposition: .newWindow)
        case (1, false, false): requestDispatchAttach(ref, from: origin, disposition: .content)
        case (2, false, true): requestDispatchAttach(ref, from: origin, disposition: .newWindow)
        case (2, true, _): requestDispatchAttach(ref, from: origin, disposition: .content)
        default: break
        }
    }

    /// Every dispatch attach goes through here; a no-op unless the row is
    /// selectable right now.
    func requestDispatchAttach(_ ref: LeoDispatchRef, from windowID: LeoWindowID, disposition: AttachDisposition) {
        guard let target = dispatchTarget(ref) else { return }
        let dispatch = target.node.dispatch
        dispatchAttachRequested(
            .dispatch(host: ref.host, id: ref.id, title: dispatch.name ?? dispatch.role),
            windowID, disposition
        )
    }

    func dispatchTarget(_ ref: LeoDispatchRef) -> (row: LeoAgentRow, node: LeoDispatchNode)? {
        for row in snapshot.rows where row.host == ref.host {
            if let node = dispatchChildren(for: row).first(where: { $0.id == ref.id }), isDispatchSelectable(node.dispatch) {
                return (row, node)
            }
        }
        return nil
    }
}
