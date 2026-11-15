import AppKit
import SwiftUI

/// The sidebar's Return: a key equivalent for the physical Return and
/// keypad Enter keys with no ⇧⌃⌥⌘ held (B-049, B-287).
///
/// A SwiftUI `.keyboardShortcut(.return, modifiers: [])` matched by
/// character, and ⌃C types U+0003, the same character as keypad Enter. In
/// the window's key-equivalent pass, which AppKit runs for ⌃-keys before
/// the terminal's `keyDown`, it took ⌃C from a focused terminal and the
/// shell never saw it. Matching by key code leaves every ⌃-key to the
/// terminal (P1).
struct LeoSidebarReturnKey: NSViewRepresentable {
    let isEnabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> LeoSidebarReturnKeyView { LeoSidebarReturnKeyView() }

    func updateNSView(_ view: LeoSidebarReturnKeyView, context: Context) {
        view.isEnabled = isEnabled
        view.action = action
    }
}

final class LeoSidebarReturnKeyView: NSView {
    var isEnabled = false
    var action: () -> Void = {}

    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
    private static let excludedModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    /// Whether `event` is a press of Return or keypad Enter with none of
    /// ⇧⌃⌥⌘ held.
    static func matches(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && [returnKeyCode, keypadEnterKeyCode].contains(event.keyCode)
            && event.modifierFlags.isDisjoint(with: excludedModifiers)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEnabled, Self.matches(event) else { return false }
        action()
        return true
    }
}
