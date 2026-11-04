import AppKit
import SwiftUI

/// While alive, a plain Esc key-down anywhere in the app goes to `onEscape`
/// and is swallowed. The Tasks popover never becomes the key window (the
/// terminal keeps the keyboard, so typing still lands there once it
/// closes), so Esc would otherwise reach the terminal as `^[` and leave the
/// popover open.
@MainActor
final class LeoEscapeMonitor {
    static let escapeKeyCode: UInt16 = 53

    private var token: Any?

    init(onEscape: @escaping @MainActor () -> Void) {
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.isPlainEscape(event) else { return event }
            MainActor.assumeIsolated { onEscape() }
            return nil
        }
    }

    deinit {
        if let token { NSEvent.removeMonitor(token) }
    }

    private static func isPlainEscape(_ event: NSEvent) -> Bool {
        event.keyCode == escapeKeyCode && event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask)
    }
}

/// Closes the popover whose content hosts it on Esc. Lives and dies with the
/// popover's content, so the monitor is installed only while it is open.
struct LeoEscapeDismiss: NSViewRepresentable {
    @Binding var isPresented: Bool

    func makeNSView(context: Context) -> LeoEscapeMonitorView {
        LeoEscapeMonitorView(onEscape: { isPresented = false })
    }

    func updateNSView(_ view: LeoEscapeMonitorView, context: Context) {}

    static func dismantleNSView(_ view: LeoEscapeMonitorView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class LeoEscapeMonitorView: NSView {
    private var monitor: LeoEscapeMonitor?

    @MainActor
    init(onEscape: @escaping @MainActor () -> Void) {
        super.init(frame: .zero)
        monitor = LeoEscapeMonitor(onEscape: onEscape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @MainActor
    func stopMonitoring() { monitor = nil }
}
