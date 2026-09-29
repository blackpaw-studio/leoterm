import AppKit
import GhosttyKit

/// B-056: each window's live pool of hidden surface trees (`LeoLivePool`),
/// and what hiding one means for Ghostty. A pooled entry is the whole tree
/// the window showed (D-105), so B-058 can bring its split layout back.
///
/// Hidden surfaces stay attached -- the tmux client, scrollback, scroll
/// position and selection all live on -- but off the view hierarchy they
/// get no layout (so no resize, and no tmux reflow), and they are told
/// they're occluded and unfocused, so Ghostty's renderer stops drawing them
/// until they are shown again.
@MainActor final class LeoLiveSurfaces {
    typealias Tree = SplitTree<Ghostty.SurfaceView>

    private var pools: [LeoWindowID: LeoLivePool<Tree>] = [:]
    private let capacity: Int
    /// Whether a surface counts as a tmux client: a live attach.
    private let isClient: (Ghostty.SurfaceView) -> Bool
    /// Called with every tree the pool lets go (evicted, dead, or its
    /// window closed): the host closes its handles. Nothing else holds the
    /// surfaces, so they free their ptys and each tmux client detaches.
    private let letGo: (Tree) -> Void

    init(
        capacity: Int = LeoLivePoolCapacity.perWindow,
        isClient: @escaping (Ghostty.SurfaceView) -> Bool,
        letGo: @escaping (Tree) -> Void
    ) {
        self.capacity = capacity
        self.isClient = isClient
        self.letGo = letGo
    }

    /// How many tmux clients `tree` holds.
    func clients(in tree: Tree) -> Int { tree.filter(isClient).count }

    /// Whether `surface` is hidden in `window`'s pool.
    func contains(_ surface: Ghostty.SurfaceView, in window: LeoWindowID) -> Bool {
        pool(of: window).entries.contains { Self.tree($0, holds: surface) }
    }

    /// Every surface hidden in `window`'s pool.
    func hiddenSurfaces(in window: LeoWindowID) -> [Ghostty.SurfaceView] {
        pool(of: window).entries.flatMap { Array($0) }
    }

    /// `displaced` just left `window`'s content area for `shown`: it is
    /// hidden as the most recently viewed entry, then the pool is trimmed.
    /// A tree with no live attach (a plain shell) is let go straight away.
    func hide(_ displaced: Tree, in window: LeoWindowID, showing shown: Tree) {
        guard !displaced.isEmpty else { return trim(window, showing: shown) }
        displaced.forEach(Self.stopDrawing)
        pools[window] = pool(of: window).hiding(displaced)
        trim(window, showing: shown)
    }

    /// Drops what no longer fits beside `shown` (least recently viewed
    /// first) and what holds no live attach any more.
    func trim(_ window: LeoWindowID, showing shown: Tree) {
        let (trimmed, evicted) = pool(of: window).trimmed(shownClients: clients(in: shown), clients: clients(in:))
        store(trimmed, for: window)
        evicted.forEach(letGo)
    }

    /// The hidden tree holding `surface`, taken out of the pool to be
    /// shown. `nil` (and the tree let go) when none, or nothing in it is
    /// still attached.
    func take(treeHolding surface: Ghostty.SurfaceView, in window: LeoWindowID) -> Tree? {
        let (remaining, taken) = pool(of: window).taking { Self.tree($0, holds: surface) }
        store(remaining, for: window)
        guard let taken else { return nil }
        guard clients(in: taken) > 0 else {
            letGo(taken)
            return nil
        }
        return taken
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
        guard let pool = pools.removeValue(forKey: window) else { return }
        pool.entries.forEach(letGo)
    }

    /// Ghostty asked to close `surface` (its process ended). A shown one is
    /// its window's business; a hidden one leaves its pooled tree, and a
    /// tree left with no live attach goes. Returns whether it was hidden.
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
