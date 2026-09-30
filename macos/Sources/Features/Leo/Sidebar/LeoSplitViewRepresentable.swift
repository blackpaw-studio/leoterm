import AppKit
import SwiftUI

/// Bridges an `NSSplitViewController` into SwiftUI so the agents sidebar has
/// a genuine `NSSplitView` divider: authoritative resize callbacks instead
/// of `NSApp.currentEvent` sniffing, true pane collapse instead of a
/// hidden/zero-width view, and a real accessibility splitter (VoiceOver can
/// adjust it out of the box, no custom `accessibilityAdjustableAction`
/// needed).
///
/// Window resizes are kept from disturbing the sidebar's width by giving it
/// a higher holding priority than the detail (terminal) pane: `NSSplitView`
/// resizes the lower-priority pane first, so the terminal absorbs window
/// resizes and the sidebar's reported width only changes when the user (or
/// assistive technology) actually moves the divider.
///
/// Both priorities live in `NSSplitView`'s low band (see
/// `LeoSidebarSplitMetrics`). Only their *order* matters for who absorbs a
/// window resize, and raising them out of that band freezes the pane.
struct LeoSplitViewRepresentable<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    var isSidebarVisible: Bool
    /// The width to apply when the split view is created, and again when the
    /// sidebar transitions from hidden to shown. NOT reapplied on every
    /// SwiftUI body evaluation -- once the sidebar is visible, the live
    /// `NSSplitView` owns its own width and a user drag is the only thing
    /// that should move it. Re-consulting this on every update (as a
    /// `GeometryReader`-derived value previously did) is what caused the
    /// divider to snap back to a stale value mid-drag.
    var preferredWidth: CGFloat
    var onDividerWidthChange: (CGFloat) -> Void
    let sidebar: Sidebar
    let detail: Detail
    /// The window's editor pane, a trailing item that collapses while no
    /// file is open (B-004).
    var editor: LeoEditorPaneModel?
    /// The window's workspace browser, an item on the editor's leading
    /// edge that collapses while it's closed (B-005).
    var browser: LeoWorkspaceBrowserModel?
    var onEditorPane: (LeoEditorPaneViewController) -> Void = { _ in }
    var onBrowserPane: (LeoWorkspaceBrowserViewController) -> Void = { _ in }
    /// The sidebar collapsed, or stayed collapsed, to keep the terminal at
    /// its floor (D-036, D-058).
    var onSidebarAutoCollapse: () -> Void = {}
    /// The sidebar the floor collapsed came back (D-059).
    var onSidebarAutoRestore: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> LeoSplitViewController {
        let components = LeoSplitViewControllerFactory.make(
            isSidebarVisible: isSidebarVisible,
            preferredWidth: preferredWidth,
            onDividerWidthChange: onDividerWidthChange,
            sidebar: AnyView(sidebar),
            detail: AnyView(detail),
            editor: editor,
            browser: browser,
            onSidebarAutoCollapse: onSidebarAutoCollapse,
            onSidebarAutoRestore: onSidebarAutoRestore)

        context.coordinator.sidebarHosting = components.sidebarHosting
        context.coordinator.detailHosting = components.detailHosting
        for item in components.controller.splitViewItems {
            if let pane = item.viewController as? LeoEditorPaneViewController { onEditorPane(pane) }
            if let pane = item.viewController as? LeoWorkspaceBrowserViewController { onBrowserPane(pane) }
        }

        return components.controller
    }

    func updateNSViewController(_ controller: LeoSplitViewController, context: Context) {
        controller.onDividerWidthChange = onDividerWidthChange
        controller.onSidebarAutoCollapse = onSidebarAutoCollapse
        controller.onSidebarAutoRestore = onSidebarAutoRestore
        context.coordinator.sidebarHosting?.rootView = AnyView(sidebar)
        context.coordinator.detailHosting?.rootView = AnyView(detail)

        guard let sidebarItem = controller.sidebarItem else { return }

        // Only reconcile the visible/collapsed state here -- an already
        // visible sidebar's width is left entirely alone (see
        // `preferredWidth` doc comment above). `lastKnownVisible` is how we
        // tell "the sidebar just went from hidden to shown, apply the stored
        // width" apart from "the sidebar is already shown and the user is
        // dragging it, leave it alone".
        let isShowing = isSidebarVisible && !controller.lastKnownVisible
        if isShowing, sidebarItem.isCollapsed, controller.sidebarSqueezesTerminal(atWidth: preferredWidth) {
            // D-058: stays collapsed, as if it had made room; the session
            // hears so after this update (not during it).
            let onSidebarAutoCollapse = onSidebarAutoCollapse
            DispatchQueue.main.async { onSidebarAutoCollapse() }
            return
        }
        controller.lastKnownVisible = isSidebarVisible

        guard sidebarItem.isCollapsed == isSidebarVisible else { return }
        // The user's call from here on: not the floor's to undo.
        controller.forgetFloorCollapse()

        // `isCollapsed` flips immediately while the pane's frame animates
        // over several frames. Every intermediate `splitViewDidResizeSubviews`
        // would otherwise look like a genuine user drag and persist a
        // mid-animation width, corrupting the stored preference. Suppress
        // persistence until the animation finishes.
        controller.isApplyingProgrammaticWidth = true
        let widthToApplyOnShow = preferredWidth
        NSAnimationContext.runAnimationGroup { _ in
            sidebarItem.animator().isCollapsed = !isSidebarVisible
        } completionHandler: {
            if isShowing {
                // Restore the stored width now that the pane is back in the
                // view tree; `applyProgrammaticWidth` takes over clearing
                // `isApplyingProgrammaticWidth` for us.
                controller.applyProgrammaticWidth(widthToApplyOnShow)
            } else {
                DispatchQueue.main.async {
                    controller.isApplyingProgrammaticWidth = false
                }
            }
        }
    }

    /// Holds the `NSHostingController`s so their `rootView` can be updated
    /// in place across SwiftUI body re-evaluations without recreating the
    /// AppKit view hierarchy.
    final class Coordinator: NSObject {
        var sidebarHosting: NSHostingController<AnyView>?
        var detailHosting: NSHostingController<AnyView>?
    }
}

@MainActor
enum LeoSplitViewControllerFactory {
    static func make(
        isSidebarVisible: Bool,
        preferredWidth: CGFloat,
        onDividerWidthChange: @escaping (CGFloat) -> Void,
        sidebar: AnyView,
        detail: AnyView,
        editor: LeoEditorPaneModel? = nil,
        browser: LeoWorkspaceBrowserModel? = nil,
        onSidebarAutoCollapse: @escaping () -> Void = {},
        onSidebarAutoRestore: @escaping () -> Void = {}
    ) -> (controller: LeoSplitViewController, sidebarHosting: NSHostingController<AnyView>, detailHosting: NSHostingController<AnyView>) {
        let controller = LeoSplitViewController()

        let sidebarHosting = NSHostingController(rootView: sidebar)
        sidebarHosting.view.setAccessibilityLabel("Agents sidebar")
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = LeoSidebarSplitMetrics.sidebarHoldingPriority
        sidebarItem.minimumThickness = LeoSidebarSplitMetrics.minimumWidth
        sidebarItem.maximumThickness = LeoSidebarSplitMetrics.maximumWidth
        sidebarItem.isCollapsed = !isSidebarVisible

        let detailHosting = NSHostingController(rootView: detail)
        let detailItem = NSSplitViewItem(viewController: detailHosting)
        detailItem.holdingPriority = LeoSidebarSplitMetrics.detailHoldingPriority
        detailItem.minimumThickness = LeoSidebarSplitMetrics.minimumTerminalWidth

        controller.addSplitViewItem(sidebarItem)
        controller.addSplitViewItem(detailItem)
        if let browser {
            let browserItem = NSSplitViewItem(viewController: LeoWorkspaceBrowserViewController(model: browser))
            browserItem.canCollapse = true
            browserItem.isCollapsed = !browser.isOpen
            browserItem.holdingPriority = LeoSidebarSplitMetrics.browserHoldingPriority
            browserItem.minimumThickness = LeoWorkspaceBrowserViewController.minimumWidth
            controller.addSplitViewItem(browserItem)
        }
        if let editor {
            let editorItem = NSSplitViewItem(viewController: LeoEditorPaneViewController(model: editor))
            editorItem.canCollapse = true
            editorItem.isCollapsed = !editor.isOpen
            editorItem.holdingPriority = LeoSidebarSplitMetrics.editorHoldingPriority
            editorItem.minimumThickness = LeoEditorPaneViewController.minimumWidth
            controller.addSplitViewItem(editorItem)
        }
        controller.splitView.dividerStyle = .thin
        controller.sidebarItem = sidebarItem
        controller.detailItem = detailItem
        controller.lastKnownVisible = isSidebarVisible
        controller.onDividerWidthChange = onDividerWidthChange
        controller.onSidebarAutoCollapse = onSidebarAutoCollapse
        controller.onSidebarAutoRestore = onSidebarAutoRestore
        controller.applyProgrammaticWidth(preferredWidth)

        return (controller, sidebarHosting, detailHosting)
    }
}

/// `NSSplitViewController` subclass that persists the sidebar's width
/// whenever the split view genuinely resizes it, via the inherited
/// `NSSplitViewDelegate` conformance rather than a separate notification
/// observer.
///
/// Width clamping is handled entirely by the split view items'
/// `minimumThickness`/`maximumThickness`. It deliberately does NOT implement
/// the legacy sizing delegate methods (`constrainMinCoordinate`,
/// `constrainMaxCoordinate`, `splitView(_:resizeSubviewsWithOldSize:)`):
/// implementing any of those opts the split view out of constraint-based
/// layout, which `NSSplitViewController` requires, and AppKit then throws
/// `NSInternalInconsistencyException` from `viewDidLoad` -- taking the whole
/// app down at launch.
final class LeoSplitViewController: NSSplitViewController {
    var sidebarItem: NSSplitViewItem?
    /// The terminal's item.
    var detailItem: NSSplitViewItem?
    var onDividerWidthChange: ((CGFloat) -> Void)?
    /// The sidebar was collapsed to keep the terminal at its floor; the
    /// window's session records it as hidden (not persisted).
    var onSidebarAutoCollapse: () -> Void = {}
    /// The sidebar the floor collapsed came back as the window widened
    /// (D-059); the window's session records it as shown (not persisted).
    var onSidebarAutoRestore: () -> Void = {}
    var isApplyingProgrammaticWidth = false
    var lastPersistedWidth: CGFloat = 0
    /// Tracks the sidebar's visibility as of the last `updateNSViewController`
    /// call, so a hidden-to-shown transition (which should restore the
    /// stored width) can be told apart from "already shown, leave the width
    /// the user is dragging alone".
    var lastKnownVisible = false
    /// A width requested before the split view could honour it, applied once
    /// the view reaches a window and lays out. See `applyProgrammaticWidth`.
    private var pendingWidth: CGFloat?
    /// A pane shown before the split view could lay it out, widened to its
    /// opening width once it can. See `openAtHalfWidth`.
    private var pendingOpening: NSSplitViewItem?
    /// Applies a width we chose ourselves -- at controller creation, or when
    /// the sidebar transitions from hidden to shown -- as opposed to one the
    /// user just dragged to. `isApplyingProgrammaticWidth` suppresses
    /// `splitViewDidResizeSubviews` from re-persisting this as if it were
    /// user intent.
    ///
    /// The flag is cleared on the next main-queue turn rather than
    /// synchronously after `setPosition`: the resulting
    /// `splitViewDidResizeSubviews` notification arrives on a later layout
    /// pass, not within this call, so clearing it immediately would leave
    /// the guard covering nothing and let this programmatic move get
    /// persisted as if the user had dragged there. A width that has to
    /// wait for the split view keeps the flag up until it is applied.
    func applyProgrammaticWidth(_ width: CGFloat) {
        guard isReadyToPositionDivider else {
            // The split view has no width of its own yet -- it isn't in a
            // window, or hasn't laid out -- and `setPosition` against a
            // zero-width split view is silently dropped. That is what used to
            // make the sidebar open at `minimumWidth` no matter which width
            // had been stored. Hold the width and apply it from
            // `viewDidLayout`, and deliberately do NOT touch
            // `lastPersistedWidth`: recording a width that was never applied
            // would let the next resize notification overwrite the stored
            // preference with the minimum. The guard stays up until the
            // width is applied (B-084): the layouts before that report the
            // pre-restore width, not a drag.
            pendingWidth = width
            isApplyingProgrammaticWidth = true
            return
        }

        isApplyingProgrammaticWidth = true
        splitView.setPosition(width, ofDividerAt: 0)
        lastPersistedWidth = width
        clearProgrammaticWidthFlagSoon()
    }

    /// Before `item` (the browser or the editor) is shown: if the terminal
    /// would end up under `LeoSidebarSplitMetrics.terminalFloor`, collapses
    /// the agents sidebar first (D-036). If that still isn't enough, the
    /// pane opens anyway -- the user's action is never refused. Does
    /// nothing before the split view is in a window and has a width.
    func makeRoom(forShowing item: NSSplitViewItem) {
        guard isReadyToPositionDivider, let sidebarItem, !sidebarItem.isCollapsed else { return }
        let paneWidths = splitViewItems.filter { ($0 !== detailItem && !$0.isCollapsed) || $0 === item }.map { pane in
            pane === item ? max(pane.minimumThickness, pane.viewController.view.frame.width) : pane.viewController.view.frame.width
        }
        guard squeezesTerminal(paneWidths) else { return }
        autoCollapseSidebar()
    }

    /// Whether showing the sidebar `width` wide (⌘⇧L) would take the
    /// terminal under its floor beside a side pane (D-058): it then stays
    /// collapsed, as if it had collapsed to make room. Without a side
    /// pane, or before the split view is in a window, it never does.
    func sidebarSqueezesTerminal(atWidth width: CGFloat) -> Bool {
        let sidePanes = sidePaneItems.filter { !$0.isCollapsed }
        guard isReadyToPositionDivider, let sidebarItem, !sidePanes.isEmpty else { return false }
        let sidebarWidth = min(max(width, sidebarItem.minimumThickness), sidebarItem.maximumThickness)
        return squeezesTerminal([sidebarWidth] + sidePanes.map { $0.viewController.view.frame.width })
    }

    private var sidePaneItems: [NSSplitViewItem] {
        splitViewItems.filter { $0 !== sidebarItem && $0 !== detailItem }
    }

    private func squeezesTerminal(_ paneWidths: [CGFloat]) -> Bool {
        LeoSidebarSplitMetrics.squeezesTerminal(
            splitWidth: splitView.bounds.width, paneWidths: paneWidths, dividerThickness: splitView.dividerThickness)
    }

    /// Collapses the sidebar for the terminal floor; the window's session
    /// records it as hidden. It's transient (D-059): remembered, with its
    /// width, to come back as the window widens.
    private func autoCollapseSidebar() {
        guard let sidebarItem else { return }
        floorCollapsedSidebarWidth = sidebarItem.viewController.view.frame.width
        sidebarItem.isCollapsed = true
        lastKnownVisible = false
        onSidebarAutoCollapse()
    }

    /// The width of the sidebar the floor collapsed, to restore it at.
    private var floorCollapsedSidebarWidth: CGFloat?
    /// The side pane the floor squeezed, and its width before.
    private var squeezedPane: (item: NSSplitViewItem, width: CGFloat)?

    /// The user showed or hid the sidebar: a collapse the floor made is
    /// no longer the floor's to undo.
    func forgetFloorCollapse() {
        floorCollapsedSidebarWidth = nil
    }

    private func restoreSidebar() {
        guard let sidebarItem, let width = floorCollapsedSidebarWidth else { return }
        floorCollapsedSidebarWidth = nil
        isApplyingProgrammaticWidth = true
        sidebarItem.isCollapsed = false
        lastKnownVisible = true
        applyProgrammaticWidth(width)
        onSidebarAutoRestore()
    }

    /// How far the pane the floor squeezed is under its earlier width;
    /// forgotten once it's back, or closed.
    private func squeezedPaneRegrowth() -> CGFloat {
        guard let squeezed = squeezedPane, !squeezed.item.isCollapsed else {
            squeezedPane = nil
            return 0
        }
        let regrowth = squeezed.width - squeezed.item.viewController.view.frame.width
        if regrowth <= 0.5 { squeezedPane = nil }
        return max(0, regrowth)
    }

    /// The shown side pane a move of the terminal's trailing divider
    /// resizes: the one with the lowest holding priority (the editor).
    private var absorbingPane: NSSplitViewItem? {
        sidePaneItems.filter { !$0.isCollapsed }.min { $0.holdingPriority < $1.holdingPriority }
    }

    /// The split's width at the last layout, to tell a narrowing window
    /// from a divider drag.
    private var lastSplitWidth: CGFloat?
    /// The absorbing pane and its width before this layout: a jump (zoom,
    /// tiling) squeezes it within the resize's own layout, before the
    /// floor acts, so its earlier width is only known from here.
    private var paneBeforeLayout: (item: NSSplitViewItem, width: CGFloat)?

    /// Keeps the terminal floor as the window resizes (D-058): see
    /// `LeoSidebarSplitMetrics.floorStep`. The split's width change is
    /// taken now; the step is decided and applied after this layout pass
    /// (the split's items can't change mid-layout, and the panes' frames
    /// are only final then).
    private func keepTerminalFloor() {
        guard isReadyToPositionDivider else { return }
        let splitWidth = splitView.bounds.width
        let change = lastSplitWidth.map { splitWidth - $0 } ?? 0
        lastSplitWidth = splitWidth
        guard abs(change) > 0.5 else { return }
        let paneBefore = change < 0 ? paneBeforeLayout : nil
        DispatchQueue.main.async { [weak self] in
            self?.applyFloorStep(splitWidthChange: change, paneBefore: paneBefore)
        }
    }

    /// The window narrowed and the split itself took from the absorbing
    /// pane, `before` as it was: a squeeze to undo on widening (B-037).
    private func rememberSqueeze(from before: (item: NSSplitViewItem, width: CGFloat)?) {
        guard squeezedPane == nil, let before, !before.item.isCollapsed,
              before.item.viewController.view.frame.width < before.width - 0.5 else { return }
        squeezedPane = before
    }

    /// `paneBefore`: the absorbing pane before a narrowing, which the
    /// split may already have squeezed. `isFollowUp`: the step before this
    /// one, in the same resize, moved something itself -- no later layout
    /// asks again, so this asks once.
    private func applyFloorStep(
        splitWidthChange: CGFloat, paneBefore: (item: NSSplitViewItem, width: CGFloat)? = nil, isFollowUp: Bool = false
    ) {
        guard isReadyToPositionDivider, let sidebarItem, let detailItem else { return }
        view.layoutSubtreeIfNeeded()
        rememberSqueeze(from: paneBefore)
        let step = LeoSidebarSplitMetrics.floorStep(LeoSidebarSplitMetrics.FloorState(
            terminalWidth: detailItem.viewController.view.frame.width, splitWidthChange: splitWidthChange,
            isSidebarShown: !sidebarItem.isCollapsed, isSidePaneShown: sidePaneItems.contains { !$0.isCollapsed },
            paneRegrowth: squeezedPaneRegrowth(),
            restorableSidebarWidth: sidebarItem.isCollapsed ? floorCollapsedSidebarWidth.map { $0 + splitView.dividerThickness } : nil))
        switch step {
        case .none: break
        case .collapseSidebar:
            autoCollapseSidebar()
            // Not a resize, so no later layout asks again: whatever the
            // sidebar didn't free, the side panes give now.
            if !isFollowUp { applyFloorStep(splitWidthChange: splitWidthChange, isFollowUp: true) }
        case let .widenTerminal(deficit): widenTerminal(by: deficit)
        case let .growPane(amount):
            moveTerminalTrailingDivider(by: -amount)
            // A jump wide enough for the pane and the sidebar: the sidebar
            // the floor collapsed comes back too (B-037).
            if !isFollowUp { applyFloorStep(splitWidthChange: splitWidthChange, isFollowUp: true) }
        case .restoreSidebar: restoreSidebar()
        }
    }

    /// Moves the terminal's trailing divider `deficit` over, at most what
    /// the side panes have above their minimums: the holding priorities
    /// then take it from the editor first, then the browser. A divider
    /// move (unlike changing priorities) also resets the panes' preferred
    /// widths, so widening the window again goes to the terminal -- after
    /// the squeezed pane (remembered here) grows back.
    private func widenTerminal(by deficit: CGFloat) {
        let slack = sidePaneItems.filter { !$0.isCollapsed }.reduce(0) { total, pane in
            total + max(0, pane.viewController.view.frame.width - pane.minimumThickness)
        }
        let move = min(deficit, slack)
        guard move > 0.5 else { return }
        if squeezedPane == nil, let pane = absorbingPane {
            squeezedPane = (pane, pane.viewController.view.frame.width)
        }
        moveTerminalTrailingDivider(by: move)
    }

    /// Positive widens the terminal, negative gives the side panes more.
    private func moveTerminalTrailingDivider(by offset: CGFloat) {
        let panes = splitView.arrangedSubviews
        guard let detailItem, panes.count == splitViewItems.count,
              let terminalIndex = splitViewItems.firstIndex(of: detailItem), terminalIndex < panes.count - 1 else { return }
        splitView.setPosition(panes[terminalIndex].frame.maxX + offset, ofDividerAt: terminalIndex)
    }

    /// After `item` (the editor) is shown: widens it to half of what it
    /// shares with the terminal (`LeoSidebarSplitMetrics.openingPaneWidth`,
    /// D-038) once the un-collapse has laid out, as the sidebar gets its
    /// stored width back after it's shown. Before the split view is in a
    /// window and has a width, that waits for its first layout.
    ///
    /// Only the terminal's trailing divider moves: the holding priorities
    /// then keep a shown browser's width and give the editor what the
    /// terminal gives up, collapsed browser or not; the sidebar isn't
    /// touched.
    func openAtHalfWidth(_ item: NSSplitViewItem) {
        guard isReadyToPositionDivider else {
            pendingOpening = item
            return
        }
        view.layoutSubtreeIfNeeded()
        // The split's own subviews: an item's view may sit in a wrapper.
        let panes = splitView.arrangedSubviews
        guard !item.isCollapsed, let detailItem, panes.count == splitViewItems.count,
              let terminalIndex = splitViewItems.firstIndex(of: detailItem), let index = splitViewItems.firstIndex(of: item) else { return }
        let width = panes[index].frame.width
        let terminal = panes[terminalIndex].frame
        let opening = LeoSidebarSplitMetrics.openingPaneWidth(sharedWidth: width + terminal.width, minimum: item.minimumThickness)
        guard opening > width + 0.5 else { return }
        splitView.setPosition(terminal.maxX - (opening - width), ofDividerAt: terminalIndex)
    }

    override func viewWillLayout() {
        super.viewWillLayout()
        paneBeforeLayout = absorbingPane.map { ($0, $0.viewController.view.frame.width) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let item = pendingOpening, isReadyToPositionDivider {
            // Outside this layout pass.
            pendingOpening = nil
            DispatchQueue.main.async { [weak self] in self?.openAtHalfWidth(item) }
        }
        keepTerminalFloor()
        guard let width = pendingWidth, isReadyToPositionDivider else { return }
        pendingWidth = nil
        applyProgrammaticWidth(width)
    }

    /// Whether `setPosition(_:ofDividerAt:)` can actually take effect.
    private var isReadyToPositionDivider: Bool {
        view.window != nil && splitView.bounds.width > 0
    }

    /// Clears the guard on the next main-queue turn rather than synchronously:
    /// the resulting `splitViewDidResizeSubviews` notification arrives on a
    /// later layout pass, so clearing it immediately would leave the guard
    /// covering nothing.
    private func clearProgrammaticWidthFlagSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.isApplyingProgrammaticWidth = false
        }
    }

    /// Persists the sidebar's current width whenever the split view reports
    /// a resize, as long as the sidebar isn't collapsed and the width
    /// actually moved. This fires for both a genuine divider drag and an
    /// assistive-technology-driven adjustment (e.g. VoiceOver incrementing
    /// the divider) -- both are real user intent and both should be
    /// remembered. Window resizes don't reach here because the sidebar's
    /// holding priority keeps its width fixed while the terminal pane
    /// absorbs the change; programmatic width changes we make ourselves are
    /// excluded via `isApplyingProgrammaticWidth`.
    ///
    /// Nor does a layout before the stored width is applied (B-084): the
    /// split view isn't in a window yet, or still holds `pendingWidth`, so
    /// the width it reports is the minimum or fitting width, and persisting
    /// it would lose the stored width at the next launch.
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)

        guard !isApplyingProgrammaticWidth, pendingWidth == nil, isReadyToPositionDivider else { return }
        guard let sidebarItem, !sidebarItem.isCollapsed else { return }
        let width = sidebarItem.viewController.view.frame.width
        guard LeoSidebarSplitMetrics.shouldPersist(newWidth: width, lastPersistedWidth: lastPersistedWidth, isCollapsed: false) else {
            return
        }
        lastPersistedWidth = width
        onDividerWidthChange?(width)
    }
}

extension NSViewController {
    /// Collapses or shows this controller's own split item (the browser's
    /// or the editor's). Showing it makes room for it first, and with
    /// `openingAtHalfWidth` then widens it to half of what it shares with
    /// the terminal.
    func setLeoSplitItemCollapsed(_ collapsed: Bool, openingAtHalfWidth: Bool = false) {
        guard let split = parent as? NSSplitViewController, let item = split.splitViewItem(for: self), item.isCollapsed != collapsed else { return }
        let leoSplit = split as? LeoSplitViewController
        if !collapsed { leoSplit?.makeRoom(forShowing: item) }
        item.isCollapsed = collapsed
        if !collapsed, openingAtHalfWidth { leoSplit?.openAtHalfWidth(item) }
    }
}
