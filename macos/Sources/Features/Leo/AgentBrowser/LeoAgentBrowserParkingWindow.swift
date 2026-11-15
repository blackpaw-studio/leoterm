import AppKit

/// Where an agent-browser tab's web view lives while no pane shows it: a
/// borderless window outside every screen. The view stays in a window, so
/// it keeps rendering and takes synthesized input, but no one can see,
/// click or focus it, and it never shows in the Windows menu or the
/// window cycle. It moves when the screens change, so none ever reaches
/// it.
final class LeoAgentBrowserParkingWindow: NSWindow {
    private let screens: () -> [NSRect]

    init(
        size: CGSize, screens: @escaping () -> [NSRect] = { NSScreen.screens.map(\.frame) },
        notificationCenter: NotificationCenter = .default
    ) {
        self.screens = screens
        super.init(
            contentRect: Self.frame(size: size, screens: screens()),
            styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.transient, .ignoresCycle]
        hasShadow = false
        animationBehavior = .none
        contentView = NSView(frame: NSRect(origin: .zero, size: size))
        orderBack(nil)
        notificationCenter.addObserver(
            self, selector: #selector(screensDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Just past the far corner of every screen.
    static func frame(size: CGSize, screens: [NSRect]) -> NSRect {
        let bounds = screens.reduce(NSRect.zero) { $0.union($1) }
        return NSRect(origin: CGPoint(x: bounds.maxX + 1_000, y: bounds.maxY + 1_000), size: size)
    }

    @objc private func screensDidChange(_ notification: Notification) {
        setFrameOrigin(Self.frame(size: frame.size, screens: screens()).origin)
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
