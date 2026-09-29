import AppKit
import GhosttyKit

/// B-056: each window's live pool of hidden surface trees (`LeoLivePool`),
/// and what hiding one means for Ghostty. A pooled entry is the whole tree
/// the window showed (D-105), so B-058 can bring its split layout back.
///
/// B-057 (D-111): beside the pool, each window keeps its terminal rows'
/// hidden shells for as long as their rows live -- never evicted, never
/// counted against the pool's tmux clients. Only closing the shell (or its
/// window) ends one, or its process ending: a shell that has exited is
/// never kept, nor shown again.
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
    /// Whether a surface's process has ended.
    private let hasExited: (Ghostty.SurfaceView) -> Bool
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
        letGo: @escaping (Tree) -> Void
    ) {
        self.capacity = capacity
        self.isAgent = isAgent
        self.isTerminalRow = isTerminalRow
        self.isClient = isClient
        self.hasExited = hasExited
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
    /// terminal row's shell alone: kept for the row -- unless it has
    /// already ended (Ghostty waiting for a key), when there is nothing to
    /// come back to and it is let go with its row. Anything else -- a
    /// plain shell beside an agent or a row -- is let go straight away
    /// (D-106 asked before closing a busy one): no hidden tree holds a
    /// shell for a later eviction or close to kill silently. Then the pool
    /// is trimmed.
    func hide(_ displaced: Tree, in window: LeoWindowID, showing shown: Tree) {
        switch LeoContentReplacement.fate(displaced.map(kind)) {
        case .pool:
            displaced.forEach(Self.stopDrawing)
            pools[window] = pool(of: window).hiding(displaced)
        case .keep where holdsExitedShell(displaced):
            letGo(displaced)
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
    /// tree with nothing in it still attached, or a kept one whose shell
    /// has exited, is let go instead.
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
        guard let tree = removeKept(treeHolding: surface, in: window) else { return nil }
        guard !holdsExitedShell(tree) else {
            letGo(tree)
            return nil
        }
        return tree
    }

    private func removeKept(treeHolding surface: Ghostty.SurfaceView, in window: LeoWindowID) -> Tree? {
        guard let trees = kept[window], let index = trees.firstIndex(where: { Self.tree($0, holds: surface) }) else { return nil }
        storeKept(trees.enumerated().filter { $0.offset != index }.map(\.element), for: window)
        return trees[index]
    }

    /// A kept tree whose row's shell has ended: nothing to show it by.
    private func holdsExitedShell(_ tree: Tree) -> Bool {
        tree.contains { isTerminalRow($0) && hasExited($0) }
    }

    /// A terminal row closed while its shell was hidden (B-057): the tree
    /// kept for it is taken out and let go. A kept tree is only ever that
    /// row's shell (`LeoContentReplacement.fate` keeps nothing else), so no
    /// other shell goes with it. `false` when nothing in `window`'s keep
    /// holds `surface`: already let go, or never kept.
    @discardableResult
    func discardKept(treeHolding surface: Ghostty.SurfaceView, in window: LeoWindowID) -> Bool {
        guard let tree = removeKept(treeHolding: surface, in: window) else { return false }
        letGo(tree)
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
        let terminals = kept.removeValue(forKey: window) ?? []
        (pooled + terminals).forEach(letGo)
    }

    /// Ghostty asked to close `surface` (its process ended). A shown one is
    /// its window's business; a pooled one leaves its tree, and a tree
    /// left with no live attach goes. Returns whether it was pooled. Not
    /// pooled is the common case, not an error: the host hears every close
    /// request, and nearly all name a surface on screen, which its
    /// controller closes -- so this deliberately does nothing then. Nor
    /// does it touch a shell kept for a terminal row: that ends only by its
    /// row's close (`discardKept`), which the host routes the request to.
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
    /// placeholder when revealed. A kept row whose shell ended goes too --
    /// its row with it -- whether or not Ghostty also asks to close it
    /// (it doesn't when it waits for a key, or the exit was abnormally
    /// quick).
    func dropDead() {
        for window in pools.keys {
            let (remaining, dead) = pool(of: window).removing { clients(in: $0) == 0 }
            store(remaining, for: window)
            dead.forEach(letGo)
        }
        for (window, trees) in kept {
            storeKept(trees.filter { !holdsExitedShell($0) }, for: window)
            trees.filter(holdsExitedShell).forEach(letGo)
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
