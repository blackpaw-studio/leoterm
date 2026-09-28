import AppKit
import SwiftUI

/// Reports left clicks on the view it backs, read from the mouse events
/// themselves (B-048). A SwiftUI tap gesture in a list row never fires in
/// a window that isn't key -- and a ⌘-click on a background window doesn't
/// make it key -- while the list still selects the row. A local event
/// monitor sees every click the app dispatches, key window or not, with
/// the event's own modifiers and click count. The view takes no part in
/// hit testing, so the list and the row's other gestures see each click
/// as before. The row has no controls of its own (B-049), so every click
/// inside it is a row click.
struct LeoRowClickCatcher: NSViewRepresentable {
    /// The row this view currently backs (its agent's id).
    let identity: AnyHashable
    let onClick: (NSEvent.ModifierFlags, Int) -> Void

    func makeNSView(context: Context) -> LeoRowClickCatcherView { LeoRowClickCatcherView() }

    func updateNSView(_ view: LeoRowClickCatcherView, context: Context) {
        view.identity = identity
        view.onClick = onClick
        view.isEnabled = context.environment.isEnabled
    }
}

final class LeoRowClickCatcherView: NSView {
    var onClick: (NSEvent.ModifierFlags, Int) -> Void = { _, _ in }
    var isEnabled = true
    /// The row this view backs. Rows re-sort live, and SwiftUI may hand
    /// this view (with a new `onClick`) to another row between mouse-down
    /// and mouse-up; that mouse-up is no click on the new row (B-049).
    var identity: AnyHashable?
    private var monitor: Any?
    /// The row the last mouse-down landed on, when it landed here: the
    /// matching mouse-up is a click only on that same row (a drag in from
    /// another row, or a rebind to another agent, is not).
    private var armed: Armed?

    private struct Armed { let identity: AnyHashable? }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
            let isArmed = isInside && isEnabled && !event.modifierFlags.contains(.control)
            armed = isArmed ? Armed(identity: identity) : nil
        case .leftMouseUp:
            defer { armed = nil }
            guard let armed, armed.identity == identity, isInside, isEnabled else { return }
            onClick(event.modifierFlags, event.clickCount)
        default:
            break
        }
    }

    private func contains(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
        // `visibleRect` alone can reach past the view's own bounds.
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point) && visibleRect.contains(point)
    }

    private func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}

/// VoiceOver's press on a row (AXPress): a plain single click, so it goes
/// wherever a click goes -- the agent's tab, a new attach, or the Start
/// prompt (B-049).
enum LeoRowAccessibility {
    static let pressName = "Open"

    static func press(_ click: (NSEvent.ModifierFlags, Int) -> Void) {
        click([], 1)
    }
}
