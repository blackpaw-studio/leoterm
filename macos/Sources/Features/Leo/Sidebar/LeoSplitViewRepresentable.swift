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
            browser: browser)

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
        controller.lastKnownVisible = isSidebarVisible

        guard sidebarItem.isCollapsed == isSidebarVisible else { return }

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
        browser: LeoWorkspaceBrowserModel? = nil
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
        controller.lastKnownVisible = isSidebarVisible
        controller.onDividerWidthChange = onDividerWidthChange
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
    var onDividerWidthChange: ((CGFloat) -> Void)?
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
    /// persisted as if the user had dragged there.
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
            // preference with the minimum.
            pendingWidth = width
            clearProgrammaticWidthFlagSoon()
            return
        }

        isApplyingProgrammaticWidth = true
        splitView.setPosition(width, ofDividerAt: 0)
        lastPersistedWidth = width
        clearProgrammaticWidthFlagSoon()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
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
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)

        guard !isApplyingProgrammaticWidth, let sidebarItem, !sidebarItem.isCollapsed else { return }
        let width = sidebarItem.viewController.view.frame.width
        guard LeoSidebarSplitMetrics.shouldPersist(newWidth: width, lastPersistedWidth: lastPersistedWidth, isCollapsed: false) else {
            return
        }
        lastPersistedWidth = width
        onDividerWidthChange?(width)
    }
}
