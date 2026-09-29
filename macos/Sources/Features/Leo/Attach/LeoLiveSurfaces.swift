import AppKit
import GhosttyKit

/// B-056: each window's live pool of hidden surface trees (`LeoLivePool`),
/// and what hiding one means for Ghostty. A pooled entry is the whole tree
/// the window showed (D-105), so B-058 can bring its split layout back.
///
/// B-057 (D-111): beside the pool, each window keeps its terminal rows'
/// hidden shells for as long as their rows live -- never evicted, never
/// counted against the pool's tmux clients. Only closing the shell (or its
/// window) ends one.
///
/// Hidden surfaces stay attached -- the tmux client, scrollback, scroll
/// position and selection all live on -- but off the view hierarchy they
/// get no layout (so no resize, and no tmux reflow), and they are told
/// they're occluded and unfocused, so Ghostty's renderer stops drawing them
/// until they are shown again.
@MainActor final class LeoLiveSurfaces {
    typealias Tree = SplitTree<Ghostty.SurfaceView>

    private var pools: [LeoWindowID: LeoLivePool<Tree>] = [:]
    /// Each window's hidden terminal-row trees, oldest first (B-057).
    private var kept: [LeoWindowID: [Tree]] = [:]
    private let capacity: Int
    /// Whether a surface counts as a tmux client: a live attach.
    private let isClient: (Ghostty.SurfaceView) -> Bool
    /// Whether a surface is an agent attach (live or exited), not a shell.
    private let isAgent: (Ghostty.SurfaceView) -> Bool
    /// Whether a surface is a terminal row's own shell (B-057).
    private let isTerminalRow: (Ghostty.SurfaceView) -> Bool
    /// Called with every tree the pool lets go (evicted, dead, or its
    /// window closed): the host closes its handles. Nothing else holds the
    /// surfaces, so they free their ptys and each tmux client detaches.
    private let letGo: (Tree) -> Void

    init(
        capacity: Int = LeoLivePoolCapacity.perWindow,
        isAgent: @escaping (Ghostty.SurfaceView) -> Bool,
        isTerminalRow: @escaping (Ghostty.SurfaceView) -> Bool = { _ in false },
        isClient: @escaping (Ghostty.SurfaceView) -> Bool,
        letGo: @escaping (Tree) -> Void
    ) {
        self.capacity = capacity
        self.isAgent = isAgent
        self.isTerminalRow = isTerminalRow
        self.isClient = isClient
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
        (kept[window] ?? []).flatMap { Array($0) }
    }

    /// `displaced` just left `window`'s content area for `shown`. All
    /// agents: hidden in the pool as the most recently viewed entry. A
    /// terminal row's tree: kept for the row. Anything else -- a plain
    /// shell beside an agent -- is let go straight away (D-106 asked before
    /// closing a busy one): no shell is ever in the pool for a later
    /// eviction to kill silently. Then the pool is trimmed.
    func hide(_ displaced: Tree, in window: LeoWindowID, showing shown: Tree) {
        switch LeoContentReplacement.fate(displaced.map(kind)) {
        case .pool:
            displaced.forEach(Self.stopDrawing)
            pools[window] = pool(of: window).hiding(displaced)
        case .keep:
            displaced.forEach(Self.stopDrawing)
            kept[window, default: []].append(displaced)
        case .close:
            letGo(displaced)
        }
        trim(window, showing: shown)
    }

    private func kind(_ surface: Ghostty.SurfaceView) -> LeoContentReplacement.Shown {
        LeoContentReplacement.Shown(isAgent: isAgent(surface), isTerminalRow: isTerminalRow(surface), needsConfirmQuit: false)
    }

    private func hiddenTrees(in window: LeoWindowID) -> [Tree] {
        pool(of: window).entries + (kept[window] ?? [])
    }

    /// Drops what no longer fits beside `shown` (least recently viewed
    /// first) and what holds no live attach any more.
    func trim(_ window: LeoWindowID, showing shown: Tree) {
        let (trimmed, evicted) = pool(of: window).trimmed(shownClients: clients(in: shown), clients: clients(in:))
        store(trimmed, for: window)
        evicted.forEach(letGo)
    }

    /// The hidden tree holding `surface`, taken out of the pool (or the
    /// terminal rows' keep) to be shown. `nil` when none -- and a pooled
    /// tree with nothing in it still attached is let go instead.
    func take(treeHolding surface: Ghostty.SurfaceView, in window: LeoWindowID) -> Tree? {
        if let terminal = takeKept(treeHolding: surface, in: window) { return terminal }
        let (remaining, taken) = pool(of: window).taking { Self.tree($0, holds: surface) }
        store(remaining, for: window)
        guard let taken else { return nil }
        guard clients(in: taken) > 0 else {
            letGo(taken)
            return nil
        }
        return taken
    }

    private func takeKept(treeHolding surface: Ghostty.SurfaceView, in window: LeoWindowID) -> Tree? {
        guard let trees = kept[window], let index = trees.firstIndex(where: { Self.tree($0, holds: surface) }) else { return nil }
        storeKept(trees.enumerated().filter { $0.offset != index }.map(\.element), for: window)
        return trees[index]
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
        let terminals = kept.removeValue(forKey: window) ?? []
        (pooled + terminals).forEach(letGo)
    }

    /// Ghostty asked to close `surface` (its process ended). A shown one is
    /// its window's business; a hidden one leaves its pooled tree, and a
    /// tree left with no live attach goes. Returns whether it was hidden.
    /// Not hidden is the common case, not an error: the host hears every
    /// close request, and nearly all name a surface on screen, which its
    /// controller closes -- so this deliberately does nothing then.
    @discardableResult
    func surfaceClosed(_ surface: Ghostty.SurfaceView) -> Bool {
        if keptSurfaceClosed(surface) { return true }
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

    /// A kept shell's process ended (`exit`): it leaves its tree, and a
    /// tree left with no terminal row -- nothing to show it by -- goes.
    private func keptSurfaceClosed(_ surface: Ghostty.SurfaceView) -> Bool {
        guard let window = kept.first(where: { $0.value.contains { Self.tree($0, holds: surface) } })?.key else { return false }
        let trees = (kept[window] ?? []).map { Self.removing(surface, from: $0) }
        letGo(Tree(view: surface))
        let hasRow: (Tree) -> Bool = { [isTerminalRow] in $0.contains(where: isTerminalRow) }
        storeKept(trees.filter(hasRow), for: window)
        trees.filter { !$0.isEmpty && !hasRow($0) }.forEach(letGo)
        return true
    }

    private func storeKept(_ trees: [Tree], for window: LeoWindowID) {
        kept[window] = trees.isEmpty ? nil : trees
    }

    private static func removing(_ surface: Ghostty.SurfaceView, from tree: Tree) -> Tree {
        guard let node = tree.root?.node(view: surface) else { return tree }
        return tree.removing(node)
    }

    /// A hidden surface's process ended (an agent restart ends its tmux
    /// client): hidden trees left with no live attach go. One still
    /// holding a live attach keeps the exited pane, shown again as a
    /// placeholder when revealed.
    func dropDead() {
        for window in pools.keys {
            let (remaining, dead) = pool(of: window).removing { clients(in: $0) == 0 }
            store(remaining, for: window)
            dead.forEach(letGo)
        }
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
