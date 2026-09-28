import AppKit
import SwiftUI

/// Reports left clicks on the view it backs, read from the mouse events
/// themselves (B-048). A SwiftUI tap gesture in a list row never fires in
/// a window that isn't key -- and a ⌘-click on a background window doesn't
/// make it key -- while the list still selects the row. A local event
/// monitor sees every click the app dispatches, key window or not, with
/// the event's own modifiers and click count. The view takes no part in
/// hit testing, so the list and the row's other gestures see each click
/// as before -- which is why it has to be told where the row's own
/// controls are: a click on one of those is not a row click.
struct LeoRowClickCatcher: NSViewRepresentable {
    /// A control inside the row (its Attach button), in the row's
    /// top-left-origin coordinates.
    var excluding: CGRect?
    let onClick: (NSEvent.ModifierFlags, Int) -> Void

    func makeNSView(context: Context) -> LeoRowClickCatcherView { LeoRowClickCatcherView() }

    func updateNSView(_ view: LeoRowClickCatcherView, context: Context) {
        view.onClick = onClick
        view.excludedRect = excluding
        view.isEnabled = context.environment.isEnabled
    }
}

final class LeoRowClickCatcherView: NSView {
    var onClick: (NSEvent.ModifierFlags, Int) -> Void = { _, _ in }
    var isEnabled = true
    var excludedRect: CGRect?
    private var monitor: Any?
    /// The last mouse-down landed here, so the matching mouse-up is a click
    /// (a drag in from another row is not).
    private var isArmed = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Matches SwiftUI's coordinates, so `excludedRect` needs no flip.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    deinit { removeMonitor() }

    /// A mouse-down and mouse-up both inside the visible view make a
    /// click. A Control-click is the secondary click (the context menu).
    func handle(_ event: NSEvent) {
        let isInside = contains(event)
        switch event.type {
        case .leftMouseDown:
            isArmed = isInside && isEnabled && !event.modifierFlags.contains(.control)
        case .leftMouseUp:
            defer { isArmed = false }
            guard isArmed, isInside, isEnabled else { return }
            onClick(event.modifierFlags, event.clickCount)
        default:
            break
        }
    }

    private func contains(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
        // `visibleRect` alone can reach past the view's own bounds.
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point) && visibleRect.contains(point) && excludedRect?.contains(point) != true
    }

    private func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
