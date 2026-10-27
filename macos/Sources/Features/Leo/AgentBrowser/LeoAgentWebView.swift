import AppKit
import OSLog
import WebKit

/// A tab's web view. It reports the user's own mouse and keyboard input,
/// which takes control from the agent, and ignores the events the agent's
/// input synthesizer delivers. While the agent drives, the page cannot
/// move the window's focus.
@available(macOS 14, *)
final class LeoAgentWebView: WKWebView {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "AgentBrowser")
    /// WebKit SPI switches this WebKit lacks, each logged once.
    private static var missingSwitches: Set<String> = []

    /// True for events the agent synthesized.
    var isSynthetic: @MainActor (NSEvent) -> Bool = { _ in false }
    /// Called before the user's input reaches the page.
    var onUserInput: (@MainActor () -> Void)?
    /// True while the agent's input reaches the page. Focus it moves stays
    /// in the page: a page focusing an element has WebKit make the web view
    /// first responder, and Tab past its last control has WebKit hand focus
    /// to the window's next key view. Either would take focus from the
    /// user's terminal beside the browser pane; meanwhile, neither happens.
    var isAgentDriving = false {
        didSet { setSwitch("_setShouldSuppressFirstResponderChanges:", to: isAgentDriving) }
    }

    /// A parked view's window is off every screen, which WebKit's occlusion
    /// detection takes for hidden: the page would get no animation frames.
    func keepAnimatingWhileParked() {
        setSwitch("_setWindowOcclusionDetectionEnabled:", to: false)
    }

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

    override var nextValidKeyView: NSView? {
        isAgentDriving ? nil : super.nextValidKeyView
    }

    override var previousValidKeyView: NSView? {
        isAgentDriving ? nil : super.previousValidKeyView
    }

    private func noteInput(_ event: NSEvent) {
        guard !isSynthetic(event) else { return }
        onUserInput?()
    }

    /// Sets a WebKit SPI switch. A WebKit without it keeps its default
    /// behaviour, logged once.
    private func setSwitch(_ setterName: String, to value: Bool) {
        let setter = NSSelectorFromString(setterName)
        guard responds(to: setter) else {
            if Self.missingSwitches.insert(setterName).inserted {
                Self.logger.warning("WKWebView has no \(setterName, privacy: .public); keeping WebKit's default")
            }
            return
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method(for: setter), to: Setter.self)(self, setter, value)
    }
}
