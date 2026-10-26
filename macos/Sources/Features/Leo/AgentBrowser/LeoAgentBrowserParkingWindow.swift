import AppKit

/// Where an agent-browser tab's web view lives while no pane shows it: a
/// borderless window outside every screen. The view stays in a window, so
/// it keeps rendering and takes synthesized input, but no one can see,
/// click or focus it, and it never shows in the Windows menu or the
/// window cycle.
final class LeoAgentBrowserParkingWindow: NSWindow {
    init(size: CGSize, screens: [NSRect] = NSScreen.screens.map(\.frame)) {
        super.init(
            contentRect: Self.frame(size: size, screens: screens),
            styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.transient, .ignoresCycle]
        hasShadow = false
        animationBehavior = .none
        contentView = NSView(frame: NSRect(origin: .zero, size: size))
        orderBack(nil)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Just past the far corner of every screen.
    static func frame(size: CGSize, screens: [NSRect]) -> NSRect {
        let bounds = screens.reduce(NSRect.zero) { $0.union($1) }
        return NSRect(origin: CGPoint(x: bounds.maxX + 1_000, y: bounds.maxY + 1_000), size: size)
    }

    /// Moves `view` in, filling the window, as its first responder.
    func park(_ view: NSView) {
        view.removeFromSuperview()
        guard let contentView else { return }
        view.frame = contentView.bounds
        view.autoresizingMask = [.width, .height]
        contentView.addSubview(view)
        makeFirstResponder(view)
    }

    /// Matches the pane the views would be shown in.
    func resize(to size: CGSize) {
        setContentSize(size)
    }
}
