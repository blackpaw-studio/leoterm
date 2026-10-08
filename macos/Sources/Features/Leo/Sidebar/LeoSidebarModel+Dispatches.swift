import AppKit

/// The dispatch a selection names, with the agent row it sits under.
struct LeoDispatchSelection: Equatable, Sendable {
    let ref: LeoDispatchRef
    let parent: LeoAgentRow.ID
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

    /// The selected dispatch, while it still lives under its parent row
    /// and is still attachable and that parent is still the selection.
    /// Once it ends, this is nil and the parent agent is what is selected.
    var selectedDispatch: LeoDispatchRef? {
        guard let selected = dispatchSelection, selected.parent == selection,
              dispatchTarget(selected.ref) != nil else { return nil }
        return selected.ref
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
        dispatchSelection = LeoDispatchSelection(ref: ref, parent: target.row.id)
        fenceInFlightFocusReports()
    }

    /// A click on a dispatch row: it selects, and a click opens it where
    /// an agent row's would (⌘ in a new window, ⌥-double-click likewise).
    func dispatchClicked(
        _ ref: LeoDispatchRef,
        modifierFlags: NSEvent.ModifierFlags = [],
        clickCount: Int = 1,
        from origin: LeoWindowID? = nil
    ) {
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

    private func dispatchTarget(_ ref: LeoDispatchRef) -> (row: LeoAgentRow, node: LeoDispatchNode)? {
        for row in snapshot.rows where row.host == ref.host {
            if let node = dispatchChildren(for: row).first(where: { $0.id == ref.id }), isDispatchSelectable(node.dispatch) {
                return (row, node)
            }
        }
        return nil
    }
}
