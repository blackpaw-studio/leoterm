import AppKit
import WebKit

/// A tab's web view. It reports the user's own mouse and keyboard input,
/// which takes control from the agent, and ignores the events the agent's
/// input synthesizer delivers -- including keys WebKit re-sends after the
/// page left them unhandled.
@available(macOS 14, *)
final class LeoAgentWebView: WKWebView {
    /// True for events the agent synthesized.
    var isSynthetic: @MainActor (NSEvent) -> Bool = { _ in false }
    /// Called before the user's input reaches the page.
    var onUserInput: (@MainActor () -> Void)?

    override func mouseDown(with event: NSEvent) {
        noteInput(event)
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        noteInput(event)
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        noteInput(event)
        super.otherMouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        noteInput(event)
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        noteInput(event)
        super.keyDown(with: event)
    }

    /// AppKit offers every key equivalent in a window to all its views; only
    /// one typed while the page has focus is input to it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self { noteInput(event) }
        return super.performKeyEquivalent(with: event)
    }

    private func noteInput(_ event: NSEvent) {
        guard !isSynthetic(event) else { return }
        onUserInput?()
    }
}
