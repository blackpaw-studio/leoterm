import AppKit

/// B-110: a Leo pane dragged out of one Leo window -- dropped onto a pane
/// of another, or onto no window, which opens one for it. Upstream's own
/// move registers one undo half per window (and a "New Window"), each
/// replaying a tree from before the move; a content swap in either window
/// drops only its own half (`leoForgetContentUndo`), and the half left
/// then took the pane out of every tree -- its shell freed, unasked, once
/// the redo expired -- or pulled it back into a window that had moved on.
///
/// Here the move is one "Move Split" for both windows, which replays only
/// while the move is intact: neither window has swapped since (a swap or
/// a closed window ends it), and each still shows the panes the move left
/// it. Otherwise ⌘Z does nothing, as it does after a swap (D-140): the
/// pane stays where it is and nothing frees. The move is also a boundary
/// for both windows' earlier undo, as a swap is: a tree either showed
/// before it would put the pane back without its handle, or drop it from
/// the window holding it. Whose the pane's handle is follows its tree on
/// every apply, undo and redo (`GhosttyAttachContentHost.reconcile`).
@MainActor final class LeoCrossWindowMove {
    private typealias Tree = SplitTree<Ghostty.SurfaceView>

    static let actionName = "Move Split"

    /// Where the pane went.
    private enum Landing {
        /// Onto a pane of another open Leo window.
        case pane
        /// Onto no window: one opens for it there -- anew on each redo.
        case newWindow(position: NSPoint?, isBackgroundOpaque: Bool)
    }

    /// What each window shows on either side of the move: what its undo
    /// and redo assign, and what they check is still shown. Let go when the
    /// move ends, so it keeps no pane alive past its window's content.
    private struct Trees {
        let sourceBefore: Tree
        let sourceAfter: Tree
        let destinationBefore: Tree
        let destinationAfter: Tree
    }

    private struct Entry {
        weak var move: LeoCrossWindowMove?
    }

    /// Every move an undo or redo may still replay (weakly).
    private static var live: [Entry] = []

    private weak var pane: Ghostty.SurfaceView?
    private weak var source: TerminalController?
    private weak var destination: TerminalController?
    private let ghostty: Ghostty.App
    private let landing: Landing
    private let expiry: Duration
    private var trees: Trees?
    private weak var undoManager: ExpiringUndoManager?
    /// What each window focused before the pane moved, for its undo.
    private weak var sourceFocus: Ghostty.SurfaceView?
    private weak var destinationFocus: Ghostty.SurfaceView?
    private var closeObservers: [NSObjectProtocol] = []

    /// `pane` dropped from `source` onto `destination`, whose tree becomes
    /// `landing`; `nil` unless both are Leo windows and `source` shows it.
    convenience init?(
        _ pane: Ghostty.SurfaceView,
        from source: TerminalController,
        to destination: TerminalController,
        landingAs landing: SplitTree<Ghostty.SurfaceView>
    ) {
        guard source !== destination, destination.leoSession != nil,
              let sourceAfter = Self.removing(pane, from: source) else { return nil }
        self.init(pane, from: source, to: destination, landing: .pane, trees: Trees(
            sourceBefore: source.surfaceTree, sourceAfter: sourceAfter,
            destinationBefore: destination.surfaceTree, destinationAfter: landing
        ))
    }

    /// `pane` dragged out of `source` onto no window, at `position`; `nil`
    /// unless `source` is a Leo window showing it.
    convenience init?(_ pane: Ghostty.SurfaceView, from source: TerminalController, toNewWindowAt position: NSPoint?) {
        guard let sourceAfter = Self.removing(pane, from: source) else { return nil }
        self.init(
            pane, from: source, to: nil,
            landing: .newWindow(position: position, isBackgroundOpaque: source.isBackgroundOpaque),
            trees: Trees(sourceBefore: source.surfaceTree, sourceAfter: sourceAfter, destinationBefore: Tree(), destinationAfter: Tree(view: pane))
        )
    }

    private init(_ pane: Ghostty.SurfaceView, from source: TerminalController, to destination: TerminalController?, landing: Landing, trees: Trees) {
        self.pane = pane
        self.source = source
        self.destination = destination
        self.ghostty = source.ghostty
        self.landing = landing
        self.trees = trees
        self.expiry = source.undoExpiration
        self.undoManager = source.undoManager
    }

    deinit {
        closeObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// `source`'s tree without `pane`, when `source` is a Leo window
    /// showing it.
    private static func removing(_ pane: Ghostty.SurfaceView, from source: TerminalController) -> Tree? {
        guard source.leoSession != nil, let node = source.surfaceTree.root?.node(view: pane) else { return nil }
        return source.surfaceTree.removing(node)
    }

    // MARK: Ending

    /// `controller` swapped its content (`leoForgetContentUndo`): no move
    /// it took part in replays any more.
    static func end(involving controller: TerminalController) {
        live.compactMap(\.move).filter { $0.source === controller || $0.destination === controller }.forEach { $0.end() }
    }

    /// Drops the move's undo or redo and lets go of its trees. Idempotent.
    private func end() {
        guard trees != nil else { return }
        trees = nil
        stopObservingCloses()
        undoManager?.removeAllActions(withTarget: self)
    }

    /// A window the move involves closing ends it: there is nothing left to
    /// put the pane back into, or take it from.
    private func observeCloses() {
        stopObservingCloses()
        closeObservers = [source, destination].compactMap { $0?.window }.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            }
        }
    }

    private func stopObservingCloses() {
        closeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        closeObservers = []
    }

    // MARK: Moving

    /// Moves the pane, as one undo group whose only action is the move's
    /// own, after dropping both windows' earlier undo.
    func perform() {
        [source, destination].compactMap { $0 }.forEach { undoManager?.removeAllActions(withTarget: $0) }
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        apply()
        Self.live = Self.live.filter { $0.move != nil } + [Entry(move: self)]
        register { $0.undo() }
    }

    /// Registers what ⌘Z (or redo) next replays. The action holds the move;
    /// the undo manager holds the action until it expires or is removed.
    private func register(_ replay: @escaping (LeoCrossWindowMove) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self, expiresAfter: expiry) { [self] _ in replay(self) }
        undoManager.setActionName(Self.actionName)
    }

    /// Onto a pane, it lands and then leaves its source; a source it
    /// empties (only a drop can) shows its start screen. Into a new window
    /// it leaves first, as upstream's drag does, and the window opens with
    /// it.
    private func apply() {
        guard let source, let pane, let trees else { return }
        switch landing {
        case .pane:
            guard let destination else { return }
            destinationFocus = destination.focusedSurface
            destination.surfaceTree = trees.destinationAfter
            let previous = destination.focusedSurface
            DispatchQueue.main.async { Ghostty.moveFocus(to: pane, from: previous) }
            leave(source, trees, movingFocus: true)
        case .newWindow(let position, let isBackgroundOpaque):
            sourceFocus = source.focusedSurface
            leave(source, trees, movingFocus: false)
            undoManager?.disableUndoRegistration()
            defer { undoManager?.enableUndoRegistration() }
            destination = TerminalController.newWindow(
                ghostty, tree: trees.destinationAfter, position: position,
                confirmUndo: false, inheritBackgroundOpacity: isBackgroundOpaque
            )
        }
        observeCloses()
    }

    /// `source` shows what it had less the pane, focus moving on as a
    /// split's close moves it (`leoFocusAfterClosing`). Emptied, it shows
    /// its start screen -- the window, and any rows it keeps hidden, stay.
    private func leave(_ source: TerminalController, _ trees: Trees, movingFocus: Bool) {
        guard !trees.sourceAfter.isEmpty else { return source.leoClearToStartScreen() }
        let heir = pane.flatMap { pane in
            trees.sourceBefore.root?.node(view: pane).flatMap {
                trees.sourceBefore.leoFocusAfterClosing($0, focused: source.focusedSurface)
            }
        }
        if source.focusedSurface === pane { source.focusedSurface = heir }
        source.surfaceTree = trees.sourceAfter
        guard movingFocus, let heir else { return }
        DispatchQueue.main.async { Ghostty.moveFocus(to: heir) }
    }

    /// ⌘Z: the pane goes back, while the move is intact; else nothing
    /// happens and nothing re-registers.
    private func undo() {
        guard isIntact(applied: true), let source, let destination, let trees else { return }
        switch landing {
        case .pane:
            let previous = destination.focusedSurface
            if previous === pane { destination.focusedSurface = destinationFocus }
            destination.surfaceTree = trees.destinationBefore
            let resigning = Self.resigningOnUndo(focused: previous, moved: pane, sourceWasEmptied: trees.sourceAfter.isEmpty)
            if let focus = destinationFocus {
                DispatchQueue.main.async { Ghostty.moveFocus(to: focus, from: resigning) }
            }
            restore(source, trees)
        case .newWindow:
            // Back in the source first, so the new window's close finds the
            // pane held elsewhere and its handle moves rather than closes.
            restore(source, trees)
            if let focus = sourceFocus {
                let previous = source.focusedSurface
                DispatchQueue.main.async { Ghostty.moveFocus(to: focus, from: previous) }
            }
            self.destination = nil
            observeCloses()
            undoManager?.disableUndoRegistration()
            defer { undoManager?.enableUndoRegistration() }
            // Its own tab only: tabbed since into a group (A's, even),
            // closing its window would close every tab in it, unasked.
            destination.closeTabImmediately(registerRedo: false)
        }
        register { $0.redo() }
    }

    /// What the destination's focus, going back on a drop's undo, resigns:
    /// what it focused -- unless that is the moved pane and the move had
    /// emptied its source, which focuses the pane again; resigning it a
    /// turn later would leave it reading unfocused there.
    static func resigningOnUndo<Pane: AnyObject>(focused previous: Pane?, moved pane: Pane?, sourceWasEmptied: Bool) -> Pane? {
        previous === pane && sourceWasEmptied ? nil : previous
    }

    private func restore(_ source: TerminalController, _ trees: Trees) {
        let wasEmptied = source.surfaceTree.isEmpty
        if wasEmptied { source.leoMarkFilled() }
        source.surfaceTree = trees.sourceBefore
        guard wasEmptied, let pane else { return }
        source.focusedSurface = pane
        Ghostty.moveFocus(to: pane)
    }

    /// Redo: the move again, while both windows still show what its undo
    /// left them.
    private func redo() {
        guard isIntact(applied: false) else { return }
        apply()
        register { $0.undo() }
    }

    /// Not ended, and each window open and showing the panes the move
    /// (`applied`) or its undo left it -- the same panes in the same order;
    /// a resize or zoom since doesn't count. A window the drag opened must
    /// also have no unsaved editor edits, since undo closes it.
    private func isIntact(applied: Bool) -> Bool {
        guard let trees, let source, Self.isOpen(source),
              Self.panes(source.surfaceTree) == Self.panes(applied ? trees.sourceAfter : trees.sourceBefore) else { return false }
        switch landing {
        case .pane:
            guard let destination, Self.isOpen(destination) else { return false }
            return Self.panes(destination.surfaceTree) == Self.panes(applied ? trees.destinationAfter : trees.destinationBefore)
        case .newWindow:
            guard applied else { return true }
            guard let destination, Self.isOpen(destination), !destination.leoHasUnsavedEdits else { return false }
            return Self.panes(destination.surfaceTree) == Self.panes(trees.destinationAfter)
        }
    }

    private static func isOpen(_ controller: TerminalController) -> Bool {
        controller.window != nil && !controller.leoWindowDidClose
    }

    private static func panes(_ tree: Tree) -> [ObjectIdentifier] {
        tree.map { ObjectIdentifier($0) }
    }
}

extension TerminalController {
    /// B-110: upstream's cross-window drop (`splitDidDrop`) of `pane` from
    /// `source` into this window, whose tree becomes `landing`, as a Leo
    /// move. `false` unless both are Leo windows: upstream's own path then.
    func leoMoveSplit(
        _ pane: Ghostty.SurfaceView,
        from source: BaseTerminalController,
        landingAs landing: SplitTree<Ghostty.SurfaceView>
    ) -> Bool {
        guard let source = source as? TerminalController,
              let move = LeoCrossWindowMove(pane, from: source, to: self, landingAs: landing) else { return false }
        move.perform()
        return true
    }

    /// B-110: upstream's drag of `pane` out of this window onto no window
    /// (`ghosttySurfaceDragEndedNoTarget`), as a Leo move into a new one.
    /// `false` unless this is a Leo window.
    func leoMoveToNewWindow(_ pane: Ghostty.SurfaceView, position: NSPoint?) -> Bool {
        guard let move = LeoCrossWindowMove(pane, from: self, toNewWindowAt: position) else { return false }
        move.perform()
        return true
    }
}
