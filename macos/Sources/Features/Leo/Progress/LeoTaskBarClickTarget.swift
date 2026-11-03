import AppKit
import SwiftUI

/// The click target over a row's task bar. An AppKit view that owns the
/// whole mouse-down: the sidebar list's own row selection never sees it, so
/// a bar click opens the task popover and neither selects nor attaches the
/// row (a SwiftUI `Button` inside a list row lets the list select first).
struct LeoTaskBarClickTarget: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> TargetView { TargetView() }

    func updateNSView(_ view: TargetView, context: Context) { view.action = action }

    final class TargetView: NSView {
        var action: () -> Void = {}
        private var isArmed = false

        override var mouseDownCanMoveWindow: Bool { false }

        /// A click on a window that isn't key still counts.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            isArmed = contains(event)
        }

        override func mouseUp(with event: NSEvent) {
            defer { isArmed = false }
            guard isArmed, contains(event) else { return }
            action()
        }

        private func contains(_ event: NSEvent) -> Bool {
            bounds.contains(convert(event.locationInWindow, from: nil))
        }
    }
}
