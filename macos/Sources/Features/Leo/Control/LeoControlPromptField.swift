import AppKit
import SwiftUI

/// The prompt box's single-line field. A plain `NSTextField` for the same
/// reason as the sidebar search field: Return and Escape reach the bar
/// before the field editor consumes them, focus can be taken on request
/// (Agents ▸ Message Agent) and handed back to the terminal.
@MainActor final class LeoControlPromptFieldHandle {
    fileprivate weak var field: NSTextField?

    var window: NSWindow? { field?.window }

    func focus() {
        DispatchQueue.main.async { [weak self] in
            guard let field = self?.field, let window = field.window else { return }
            window.makeFirstResponder(field)
        }
    }

    /// Hands focus back to the window's focused terminal surface.
    func focusTerminal() {
        guard let controller = field?.window?.windowController as? BaseTerminalController,
              let surface = controller.focusedSurface else { return }
        Ghostty.moveFocus(to: surface)
    }
}

struct LeoControlPromptField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let handle: LeoControlPromptFieldHandle
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.bezelStyle = .roundedBezel
        field.controlSize = .regular
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        handle.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        handle.field = field
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.isEnabled = isEnabled
        field.setAccessibilityLabel(placeholder)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        fileprivate var parent: LeoControlPromptField

        init(_ parent: LeoControlPromptField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// Return sends; Escape hands focus back to the terminal. Never
        /// mid-IME-composition.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch LeoAgentPaletteFieldCommand.action(for: commandSelector) {
            case .submit: parent.onSubmit()
            case .cancel: parent.handle.focusTerminal()
            case .moveUp, .moveDown, nil: return false
            }
            return true
        }
    }
}
