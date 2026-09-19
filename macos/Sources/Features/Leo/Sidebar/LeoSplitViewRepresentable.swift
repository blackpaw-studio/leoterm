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
struct LeoSplitViewRepresentable<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    var isSidebarVisible: Bool
    var sidebarWidth: CGFloat
    var onDividerWidthChange: (CGFloat) -> Void
    let sidebar: Sidebar
    let detail: Detail

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> LeoSplitViewController {
        let controller = LeoSplitViewController()

        let sidebarHosting = NSHostingController(rootView: AnyView(sidebar))
        sidebarHosting.view.setAccessibilityLabel("Agents sidebar")
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority.defaultHigh
        sidebarItem.minimumThickness = LeoSidebarSplitMetrics.minimumWidth
        sidebarItem.maximumThickness = LeoSidebarSplitMetrics.maximumWidth
        sidebarItem.isCollapsed = !isSidebarVisible

        let detailHosting = NSHostingController(rootView: AnyView(detail))
        let detailItem = NSSplitViewItem(viewController: detailHosting)
        detailItem.holdingPriority = NSLayoutConstraint.Priority.defaultLow
        detailItem.minimumThickness = LeoSidebarSplitMetrics.minimumTerminalWidth

        controller.addSplitViewItem(sidebarItem)
        controller.addSplitViewItem(detailItem)
        controller.splitView.dividerStyle = .thin
        controller.sidebarItem = sidebarItem
        controller.lastPersistedWidth = sidebarWidth
        controller.onDividerWidthChange = onDividerWidthChange

        context.coordinator.sidebarHosting = sidebarHosting
        context.coordinator.detailHosting = detailHosting

        controller.isApplyingProgrammaticWidth = true
        controller.splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        controller.isApplyingProgrammaticWidth = false

        return controller
    }

    func updateNSViewController(_ controller: LeoSplitViewController, context: Context) {
        controller.onDividerWidthChange = onDividerWidthChange
        context.coordinator.sidebarHosting?.rootView = AnyView(sidebar)
        context.coordinator.detailHosting?.rootView = AnyView(detail)

        guard let sidebarItem = controller.sidebarItem else { return }

        if sidebarItem.isCollapsed == isSidebarVisible {
            // `isCollapsed` flips immediately while the pane's frame animates
            // over several frames. Every intermediate `splitViewDidResizeSubviews`
            // would otherwise look like a genuine user drag and persist a
            // mid-animation width, corrupting the stored preference. Suppress
            // persistence until the animation finishes.
            controller.isApplyingProgrammaticWidth = true
            NSAnimationContext.runAnimationGroup { _ in
                sidebarItem.animator().isCollapsed = !isSidebarVisible
            } completionHandler: {
                controller.isApplyingProgrammaticWidth = false
            }
        }

        guard isSidebarVisible else { return }

        let currentWidth = sidebarItem.viewController.view.frame.width
        guard LeoSidebarSplitMetrics.shouldPersist(newWidth: sidebarWidth, lastPersistedWidth: currentWidth, isCollapsed: false) else {
            return
        }

        controller.isApplyingProgrammaticWidth = true
        controller.splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        controller.lastPersistedWidth = sidebarWidth
        controller.isApplyingProgrammaticWidth = false
    }

    /// Holds the `NSHostingController`s so their `rootView` can be updated
    /// in place across SwiftUI body re-evaluations without recreating the
    /// AppKit view hierarchy.
    final class Coordinator: NSObject {
        var sidebarHosting: NSHostingController<AnyView>?
        var detailHosting: NSHostingController<AnyView>?
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
