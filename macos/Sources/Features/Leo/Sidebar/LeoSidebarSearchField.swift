import AppKit
import SwiftUI

/// The sidebar's live search field, for the few things SwiftUI can't do
/// with a `TextField` on macOS 13: take focus on request (Agents ▸ Find
/// Agent…), tell whether it has focus, and hand focus back to the
/// terminal.
@MainActor final class LeoSidebarSearchFieldHandle {
    fileprivate weak var field: NSTextField?

    /// True while the field is being edited (its field editor is the
    /// window's first responder).
    var hasFocus: Bool {
        guard let field, let editor = field.currentEditor() else { return false }
        return field.window?.firstResponder === editor
    }

    /// Focuses the field and selects its text. Deferred a runloop turn so a
    /// sidebar that was just shown is on screen first.
    func focus() {
        DispatchQueue.main.async { [weak self] in
            guard let field = self?.field, let window = field.window else { return }
            window.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    /// Hands focus back to the window's focused terminal surface.
    func focusTerminal() {
        guard let controller = field?.window?.windowController as? BaseTerminalController,
              let surface = controller.focusedSurface else { return }
        Ghostty.moveFocus(to: surface)
    }
}

/// A plain rounded `NSTextField` so Return and Escape reach the sidebar
/// before the field editor consumes them (see `LeoAgentPaletteSearchField`
/// for why SwiftUI's `TextField` can't).
struct LeoSidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    let handle: LeoSidebarSearchFieldHandle
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.bezelStyle = .roundedBezel
        field.placeholderString = "Search agents"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.stringValue = text
        handle.field = field
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        handle.field = nsView
        guard nsView.stringValue != text else { return }
        nsView.stringValue = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        fileprivate var parent: LeoSidebarSearchField

        init(_ parent: LeoSidebarSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// ↑/↓ stay with the field editor; only Return and Escape are the
        /// sidebar's. Never mid-IME-composition.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch LeoAgentPaletteFieldCommand.action(for: commandSelector) {
            case .submit: parent.onSubmit()
            case .cancel: parent.onCancel()
            case .moveUp, .moveDown, nil: return false
            }
            return true
        }
    }
}
