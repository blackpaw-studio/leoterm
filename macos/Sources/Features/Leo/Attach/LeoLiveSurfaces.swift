import AppKit
import GhosttyKit

/// B-056: each window's live pool of hidden surface trees (`LeoLivePool`),
/// and what hiding one means for Ghostty. A pooled entry is the whole tree
/// the window showed (D-105), so B-058 can bring its split layout back.
///
/// B-057 (D-111), B-333: beside the pool, each window keeps its terminal
/// rows' hidden layouts -- a row's shell and the shells split beside it --
/// for as long as their rows live: never evicted, never counted against
/// the pool's tmux clients. Only closing the row (or its window) ends a
/// whole layout. A pane whose process ends leaves its layout -- a shell
/// that has exited is never kept, nor shown again -- and the row's own
/// pane leaving hands the row on to a pane that stays (`paneLeft`).
///
/// Hidden surfaces stay attached -- the tmux client, scrollback, scroll
/// position and selection all live on -- but off the view hierarchy they
/// get no layout (so no resize, and no tmux reflow), and they are told
/// they're occluded and unfocused, so Ghostty's renderer stops drawing them
/// until they are shown again.
@MainActor final class LeoLiveSurfaces {
    typealias Tree = SplitTree<Ghostty.SurfaceView>

    /// B-333: a terminal row's hidden layout, and the pane that had focus
    /// when it was switched away from (held weakly: a pane that left it
    /// frees).
    private struct KeptLayout {
        let tree: Tree
        weak var focused: Ghostty.SurfaceView?
    }

    private var pools: [LeoWindowID: LeoLivePool<Tree>] = [:]
    /// Each window's hidden terminal-row layouts, oldest first (B-057).
    private var kept: [LeoWindowID: [KeptLayout]] = [:]
    private let capacity: Int
    /// Whether a surface counts as a tmux client: a live attach.
    private let isClient: (Ghostty.SurfaceView) -> Bool
    /// Whether a surface is an agent attach (live or exited), not a shell.
    private let isAgent: (Ghostty.SurfaceView) -> Bool
    /// Whether a surface is a terminal row's own shell (B-057).
    private let isTerminalRow: (Ghostty.SurfaceView) -> Bool
    /// Whether a surface's process has ended.
    private let hasExited: (Ghostty.SurfaceView) -> Bool
    /// B-333: called with each pane a kept layout loses while the rest of
    /// it stays (its process ended): the host closes its handle -- the
    /// row's own pane handing its row on to `heir`, the pane the layout
    /// focuses next, in `remaining`.
    private let paneLeft: (_ pane: Ghostty.SurfaceView, _ heir: Ghostty.SurfaceView?, _ remaining: Tree) -> Void
    /// Called with every tree the pool lets go (evicted, dead, or its
    /// window closed): the host closes its handles. Nothing else holds the
    /// surfaces, so they free their ptys and each tmux client detaches.
    private let letGo: (Tree) -> Void

    init(
        capacity: Int = LeoLivePoolCapacity.perWindow,
        isAgent: @escaping (Ghostty.SurfaceView) -> Bool,
        isTerminalRow: @escaping (Ghostty.SurfaceView) -> Bool = { _ in false },
        isClient: @escaping (Ghostty.SurfaceView) -> Bool,
        hasExited: @escaping (Ghostty.SurfaceView) -> Bool = { $0.processExited },
        paneLeft: ((Ghostty.SurfaceView, Ghostty.SurfaceView?, Tree) -> Void)? = nil,
        letGo: @escaping (Tree) -> Void
    ) {
        self.capacity = capacity
        self.isAgent = isAgent
        self.isTerminalRow = isTerminalRow
        self.isClient = isClient
        self.hasExited = hasExited
        self.paneLeft = paneLeft ?? { pane, _, _ in letGo(Tree(view: pane)) }
        self.letGo = letGo
    }

    /// How many tmux clients `tree` holds.
    func clients(in tree: Tree) -> Int { tree.filter(isClient).count }

    /// Whether `surface` is hidden in `window` (its pool, or kept for its
    /// terminal row).
    func contains(_ surface: Ghostty.SurfaceView, in window: LeoWindowID) -> Bool {
        hiddenTrees(in: window).contains { Self.tree($0, holds: surface) }
    }

    /// Every surface hidden in `window`: pooled, then kept.
    func hiddenSurfaces(in window: LeoWindowID) -> [Ghostty.SurfaceView] {
        hiddenTrees(in: window).flatMap { Array($0) }
    }

    /// Every surface `window` keeps hidden for its terminal rows.
    func keptSurfaces(in window: LeoWindowID) -> [Ghostty.SurfaceView] {
        keptTrees(in: window).flatMap { Array($0) }
    }

    /// B-333: the hidden layout `window` keeps holding `surface`, left in
    /// place; `nil` when none does.
    func keptTree(holding surface: Ghostty.SurfaceView, in window: LeoWindowID) -> Tree? {
        keptLayout(holding: surface, in: window)?.tree
    }

    /// B-332: that layout with the pane it had focused when it was
    /// switched away from, left in place.
    func keptLayout(holding surface: Ghostty.SurfaceView, in window: LeoWindowID) -> (tree: Tree, focused: Ghostty.SurfaceView?)? {
        (kept[window] ?? []).first { Self.tree($0.tree, holds: surface) }.map { ($0.tree, $0.focused) }
    }

    /// `displaced` just left `window`'s content area for `shown`. All
    /// agents: hidden in the pool as the most recently viewed entry. A
    /// terminal row's layout (B-333): kept for the row, with `focused`,
    /// the pane that had focus -- less any pane whose process has already
    /// ended (Ghostty waiting for a key), which has nothing to come back
    /// to. Anything else -- a plain shell beside an agent -- is let go
    /// straight away (D-106 asked before closing a busy one): no hidden
    /// tree holds a shell for a later eviction or close to kill silently.
    /// Then the pool is trimmed.
    func hide(_ displaced: Tree, in window: LeoWindowID, showing shown: Tree, focused: Ghostty.SurfaceView? = nil) {
        switch fate(of: displaced) {
        case .pool:
            displaced.forEach(Self.stopDrawing)
            pools[window] = pool(of: window).hiding(displaced)
        case .keep:
            displaced.forEach(Self.stopDrawing)
            kept[window, default: []].append(KeptLayout(tree: displaced, focused: focused))
            prune(window)
        case .close:
            letGo(displaced)
        }
        trim(window, showing: shown)
    }

    /// `LeoContentReplacement.fate`, by what the host knows of each
    /// surface. A pane titled after an agent with no handle (an undo put
    /// it back, B-052) is no shell of a row's: a layout holding one closes
    /// rather than keep a tmux client nothing can reveal -- as the host's
    /// confirm, which counts it an agent, said it would.
    private func fate(of tree: Tree) -> LeoContentReplacement.Fate {
        let fate = LeoContentReplacement.fate(tree.map(kind))
        guard fate == .keep, tree.contains(where: { $0.leoAgentName != nil }) else { return fate }
        return .close
    }

    private func kind(_ surface: Ghostty.SurfaceView) -> LeoContentReplacement.Shown {
        LeoContentReplacement.Shown(isAgent: isAgent(surface), isTerminalRow: isTerminalRow(surface), needsConfirmQuit: false)
    }

    private func hiddenTrees(in window: LeoWindowID) -> [Tree] {
        pool(of: window).entries + keptTrees(in: window)
    }

    private func keptTrees(in window: LeoWindowID) -> [Tree] {
        (kept[window] ?? []).map(\.tree)
    }

    /// Drops what no longer fits beside `shown` (least recently viewed
    /// first) and what holds no live attach any more.
    func trim(_ window: LeoWindowID, showing shown: Tree) {
        let (trimmed, evicted) = pool(of: window).trimmed(shownClients: clients(in: shown), clients: clients(in:))
        store(trimmed, for: window)
        evicted.forEach(letGo)
    }

    /// The hidden tree holding `surface`, taken out of the pool (or the
    /// terminal rows' keep) to be shown, with the pane to focus in it: the
    /// one a kept layout had focused (B-333), else `surface`. `nil` when
    /// none -- and a pooled tree with nothing in it still attached is let
    /// go instead, as is any pane of a kept layout that has ended (its row
    /// handed on when `surface` was the row's).
    func take(treeHolding surface: Ghostty.SurfaceView, in window: LeoWindowID) -> (tree: Tree, focus: Ghostty.SurfaceView)? {
        if let layout = takeKept(treeHolding: surface, in: window) { return layout }
        let (remaining, taken) = pool(of: window).taking { Self.tree($0, holds: surface) }
        store(remaining, for: window)
        guard let taken else { return nil }
        guard clients(in: taken) > 0 else {
            letGo(taken)
            return nil
        }
        return (taken, surface)
    }

    private func takeKept(treeHolding surface: Ghostty.SurfaceView, in window: LeoWindowID) -> (tree: Tree, focus: Ghostty.SurfaceView)? {
        guard keptIndex(holding: surface, in: window) != nil else { return nil }
        prune(window)
        guard let layout = removeKept(treeHolding: surface, in: window) else { return nil }
        let focus = layout.focused.flatMap { focused in Self.tree(layout.tree, holds: focused) ? focused : nil }
        return (layout.tree, focus ?? surface)
    }

    private func keptIndex(holding surface: Ghostty.SurfaceView, in window: LeoWindowID) -> Int? {
        kept[window]?.firstIndex { Self.tree($0.tree, holds: surface) }
    }

    private func removeKept(treeHolding surface: Ghostty.SurfaceView, in window: LeoWindowID) -> KeptLayout? {
        guard let trees = kept[window], let index = keptIndex(holding: surface, in: window) else { return nil }
        storeKept(trees.enumerated().filter { $0.offset != index }.map(\.element), for: window)
        return trees[index]
    }

    /// B-333: every pane of `window`'s kept layouts whose process has
    /// ended leaves its layout (`removePanes`).
    private func prune(_ window: LeoWindowID) {
        let ended = (kept[window] ?? []).map { $0.tree.filter(hasExited) }.filter { !$0.isEmpty }
        ended.forEach { removePanes($0, in: window) }
    }

    /// B-333: `leaving` -- panes of one kept layout in `window` -- leave
    /// it. Nothing left: the whole layout is let go, its row with it.
    /// Otherwise the rest stays kept, focused on the pane Ghostty would
    /// focus once they closed, and the host hears each pane left
    /// (`paneLeft`), so the row's own pane hands its row on there. A rest
    /// that no row carries on has nothing to be shown by: it is let go.
    private func removePanes(_ leaving: [Ghostty.SurfaceView], in window: LeoWindowID) {
        guard let first = leaving.first, var layouts = kept[window], let index = keptIndex(holding: first, in: window) else { return }
        let layout = layouts[index]
        let (remaining, focus) = leaving.reduce((layout.tree, layout.focused)) { state, pane in
            guard let node = state.0.root?.node(view: pane) else { return state }
            return (state.0.removing(node), state.0.leoFocusAfterClosing(node, focused: state.1 ?? pane))
        }
        guard !remaining.isEmpty else {
            layouts.remove(at: index)
            storeKept(layouts, for: window)
            return letGo(layout.tree)
        }
        layouts[index] = KeptLayout(tree: remaining, focused: focus)
        storeKept(layouts, for: window)
        leaving.forEach { paneLeft($0, focus, remaining) }
        guard !remaining.contains(where: isTerminalRow), let rest = remaining.first else { return }
        discardKept(treeHolding: rest, in: window)
    }

    /// A terminal row closed while its layout was hidden (B-057): the
    /// layout kept for it is taken out and let go -- its shell and every
    /// shell split beside it (B-333), which its close asked about first.
    /// `false` when nothing in `window`'s keep holds `surface`: already let
    /// go, or never kept.
    @discardableResult
    func discardKept(treeHolding surface: Ghostty.SurfaceView, in window: LeoWindowID) -> Bool {
        guard let layout = removeKept(treeHolding: surface, in: window) else { return false }
        letGo(layout.tree)
        return true
    }

    /// Lets go of the hidden tree holding `surface` (the agent is wanted
    /// elsewhere: one tmux client per agent).
    func release(treeHolding surface: Ghostty.SurfaceView, in window: LeoWindowID) {
        let (remaining, removed) = pool(of: window).removing { Self.tree($0, holds: surface) }
        store(remaining, for: window)
        removed.forEach(letGo)
    }

    /// `window` closed: everything it held hidden goes with it.
    func releaseAll(in window: LeoWindowID) {
        let pooled = pools.removeValue(forKey: window)?.entries ?? []
        let terminals = kept.removeValue(forKey: window)?.map(\.tree) ?? []
        (pooled + terminals).forEach(letGo)
    }

    /// Ghostty asked to close `surface` (its process ended). A shown one is
    /// its window's business; a pooled one leaves its tree, and a tree
    /// left with no live attach goes. Returns whether it was pooled. Not
    /// pooled is the common case, not an error: the host hears every close
    /// request, and nearly all name a surface on screen, which its
    /// controller closes -- so this deliberately does nothing then. Nor
    /// does it touch a terminal row's kept layout: a pane there leaves by
    /// its exit (`keptPaneEnded`, `dropDead`), the whole layout by its
    /// row's close (`discardKept`).
    @discardableResult
    func surfaceClosed(_ surface: Ghostty.SurfaceView) -> Bool {
        guard let window = pools.first(where: { $0.value.entries.contains { Self.tree($0, holds: surface) } })?.key else {
            return false
        }
        let pool = pool(of: window)
        let entries = pool.entries.map { Self.removing(surface, from: $0) }
        letGo(Tree(view: surface))
        let isKept: (Tree) -> Bool = { [self] in clients(in: $0) > 0 }
        store(LeoLivePool(capacity: pool.capacity, entries: entries.filter(isKept)), for: window)
        entries.filter { !$0.isEmpty && !isKept($0) }.forEach(letGo)
        return true
    }

    /// B-333: Ghostty asked to close `surface`, a pane of a kept layout,
    /// its process having ended: it leaves the layout as an exit does
    /// (`dropDead`), whether or not its exit has been seen yet. `false`
    /// when no kept layout holds it.
    @discardableResult
    func keptPaneEnded(_ surface: Ghostty.SurfaceView) -> Bool {
        guard let window = kept.first(where: { $0.value.contains { Self.tree($0.tree, holds: surface) } })?.key else {
            return false
        }
        removePanes([surface], in: window)
        return true
    }

    private func storeKept(_ layouts: [KeptLayout], for window: LeoWindowID) {
        kept[window] = layouts.isEmpty ? nil : layouts
    }

    private static func removing(_ surface: Ghostty.SurfaceView, from tree: Tree) -> Tree {
        guard let node = tree.root?.node(view: surface) else { return tree }
        return tree.removing(node)
    }

    /// A hidden surface's process ended (an agent restart ends its tmux
    /// client): hidden trees left with no live attach go. One still
    /// holding a live attach keeps the exited pane, shown again as a
    /// placeholder when revealed. A kept layout's pane that ended leaves
    /// it -- its row handed on when it was the row's, the row going with
    /// the last pane (B-333) -- whether or not Ghostty also asks to close
    /// it (it doesn't when it waits for a key, or the exit was abnormally
    /// quick).
    func dropDead() {
        for window in pools.keys {
            let (remaining, dead) = pool(of: window).removing { clients(in: $0) == 0 }
            store(remaining, for: window)
            dead.forEach(letGo)
        }
        Array(kept.keys).forEach(prune)
    }

    private func pool(of window: LeoWindowID) -> LeoLivePool<Tree> {
        pools[window] ?? LeoLivePool(capacity: capacity)
    }

    private func store(_ pool: LeoLivePool<Tree>, for window: LeoWindowID) {
        pools[window] = pool.entries.isEmpty ? nil : pool
    }

    private static func tree(_ tree: Tree, holds surface: Ghostty.SurfaceView) -> Bool {
        tree.contains { $0 === surface }
    }

    /// Off screen: unfocused and occluded, so libghostty's renderer stops
    /// drawing it. The controller's occlusion sync marks it visible again
    /// when it is back in a visible window's tree.
    private static func stopDrawing(_ view: Ghostty.SurfaceView) {
        view.focusDidChange(false)
        if view.isWindowVisible, let surface = view.surface {
            ghostty_surface_set_occlusion(surface, false)
        }
        view.isWindowVisible = false
    }
}
