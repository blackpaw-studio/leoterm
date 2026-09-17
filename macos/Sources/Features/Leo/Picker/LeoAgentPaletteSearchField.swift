import AppKit
import SwiftUI

/// Maps an `NSResponder` editing command (as delivered to
/// `NSTextFieldDelegate.control(_:textView:doCommandBy:)`) to the palette
/// action it should perform. A pure function -- no AppKit/view dependency --
/// so the mapping itself is unit-testable without a live field editor.
enum LeoAgentPaletteFieldCommand: Equatable {
    case moveUp, moveDown, submit, cancel

    static func action(for selector: Selector) -> LeoAgentPaletteFieldCommand? {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): .moveUp
        case #selector(NSResponder.moveDown(_:)): .moveDown
        case #selector(NSResponder.insertNewline(_:)): .submit
        case #selector(NSResponder.cancelOperation(_:)): .cancel
        default: nil
        }
    }
}

/// A plain `NSTextField` bridged into SwiftUI so ↑/↓/Return/Esc can be
/// intercepted before the field editor consumes them -- SwiftUI's
/// `.onMoveCommand`/`.onSubmit`/`.onExitCommand` never see those keys while
/// a `TextField` has focus and text, because the field editor's own key
/// binding table claims them first. `NSTextFieldDelegate.control(_:textView:
/// doCommandBy:)` runs BEFORE that happens, so intercepting there is the
/// only reliable way to route them to the palette instead.
struct LeoAgentPaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize + 6)
        field.placeholderString = "Search agents…"
        field.delegate = context.coordinator
        field.stringValue = text
        // Requesting first responder synchronously here is too early -- the
        // field isn't in a window yet the moment `makeNSView` runs. Defer to
        // the next runloop turn, by which point `present(parent:...)` has
        // attached the hosting panel as a child window.
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        guard nsView.stringValue != text else { return }
        nsView.stringValue = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: LeoAgentPaletteSearchField

        init(_ parent: LeoAgentPaletteSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// `hasMarkedText()` on the field editor itself is the authoritative
        /// "is an IME composition in progress" signal -- never act on a
        /// navigation/submit command while it's true, or a keystroke meant
        /// to advance the composition would instead move the selection or
        /// dismiss the palette.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText(), let action = LeoAgentPaletteFieldCommand.action(for: commandSelector) else {
                return false
            }
            switch action {
            case .moveUp: parent.onMoveUp()
            case .moveDown: parent.onMoveDown()
            case .submit: parent.onSubmit()
            case .cancel: parent.onCancel()
            }
            return true
        }
    }
}
