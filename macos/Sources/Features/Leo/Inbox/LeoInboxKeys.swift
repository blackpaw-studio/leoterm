import AppKit
import SwiftUI

/// The inbox's keyboard: ↑/↓, ↩, ⌘↩ and ⌫ (`LeoInboxKeyAction`) while it
/// has the window's keyboard. It takes first responder when it appears, so a
/// terminal under the inbox never receives keystrokes meant for the list. A
/// text field in the detail keeps its own keys (arrows, Return, delete).
struct LeoInboxKeys: NSViewRepresentable {
    /// Returns whether the action did something (else the key carries on).
    let perform: (LeoInboxKeyAction) -> Bool

    func makeNSView(context: Context) -> LeoInboxKeyView {
        let view = LeoInboxKeyView()
        view.perform = perform
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: LeoInboxKeyView, context: Context) {
        view.perform = perform
    }
}

final class LeoInboxKeyView: NSView {
    var perform: (LeoInboxKeyAction) -> Bool = { _ in false }

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func keyDown(with event: NSEvent) {
        if let action = LeoInboxKeyAction.action(keyCode: event.keyCode, modifiers: event.modifierFlags),
           action != .goToAgent, perform(action) {
            return
        }
        super.keyDown(with: event)
    }

    /// ⌘↩ travels the key-equivalent pass, whoever has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.isKeyWindow == true,
              LeoInboxKeyAction.action(keyCode: event.keyCode, modifiers: event.modifierFlags) == .goToAgent else { return false }
        return perform(.goToAgent)
    }
}
