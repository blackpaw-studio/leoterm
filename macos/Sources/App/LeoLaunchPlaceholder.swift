import AppKit

/// What `LeoLaunchPlaceholder` needs from the window a launch opened.
@MainActor
protocol LeoLaunchPlaceholderWindow: AnyObject {
    /// Still the empty start screen it opened with: it never showed an
    /// agent or a terminal, and no sheet is up on it.
    var isPristineLeoPlaceholder: Bool { get }
    /// The next window to cascade lands on this window's spot.
    func holdSpotForReplacement()
    /// Closes it for good (no confirmation, nothing to undo), still holding
    /// its spot for the window replacing it.
    func closeReplacedLeoPlaceholder()
    /// Calls `onClose` when the window closes, until the returned function
    /// is called.
    func observeLeoWindowClose(_ onClose: @escaping @MainActor @Sendable () -> Void) -> () -> Void
}

/// What `LeoLaunchPlaceholder` needs from a window something asked for.
@MainActor
protocol LeoRequestedWindow: AnyObject {
    /// On screen: its presentation ran, and it hasn't closed.
    var isLeoWindowShown: Bool { get }
}

/// The empty window a launch opened on its own (B-085) gives way to the
/// first window something asks for -- a script's `make new window`, an App
/// Intent, a Service, an opened file, a notification -- as an untouched
/// untitled document does in a document app. A cold launch those start
/// then ends with one window, whether or not AppKit counted it as a
/// default launch.
///
/// The launch window stays for good once the user touches Leo (a key or
/// mouse press or a scroll anywhere in the app), once it shows anything or
/// has a sheet up, or when the window asked for is its own (a start-screen
/// button, pressed by accessibility, say). It is let go when it closes.
@MainActor
final class LeoLaunchPlaceholder {
    /// The input that counts as the user touching Leo.
    nonisolated static let touchEvents: NSEvent.EventTypeMask = [
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]

    private weak var window: (any LeoLaunchPlaceholderWindow)?
    private var stopObserving: [() -> Void] = []
    private let adoptsLaunchWindows: Bool
    private let observeUserInput: (@escaping @MainActor @Sendable () -> Void) -> () -> Void
    private let schedule: (@escaping @MainActor @Sendable () -> Void) -> Void

    /// `adoptsLaunchWindows` is false in an XCTest host, whose tests open
    /// real windows and must not close the host's launch window.
    /// `observeUserInput` calls its argument on the user's first touch and
    /// returns a function that stops observing.
    init(
        adoptsLaunchWindows: Bool = true,
        observeUserInput: @escaping (@escaping @MainActor @Sendable () -> Void) -> () -> Void = LeoLaunchPlaceholder.observeLocalInput,
        schedule: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void = LeoInitialWindowOpener.onNextMainQueueTurn
    ) {
        self.adoptsLaunchWindows = adoptsLaunchWindows
        self.observeUserInput = observeUserInput
        self.schedule = schedule
    }

    /// The launch window still waiting to give way, if any.
    var launchWindow: (any LeoLaunchPlaceholderWindow)? { window }

    /// The launch opened `window` for nobody in particular.
    func launchDidOpen(_ window: any LeoLaunchPlaceholderWindow) {
        guard adoptsLaunchWindows else { return }
        adopt(window)
    }

    /// Treat `window` as the launch's own window.
    func adopt(_ window: any LeoLaunchPlaceholderWindow) {
        settle()
        self.window = window
        stopObserving = [
            observeUserInput { [weak self] in self?.settle() },
            window.observeLeoWindowClose { [weak self] in self?.settle() },
        ]
    }

    /// `requested` just opened, `parent` (if any) having asked for it. A
    /// pristine launch window gives way to it: `requested` cascades onto
    /// its spot, and the launch window closes once `requested` has shown
    /// (that presentation is already on the main queue). If `requested`
    /// never shows, the launch window stays: never no window.
    func windowDidOpen(_ requested: any LeoRequestedWindow, parent: AnyObject? = nil) {
        guard let placeholder = window, placeholder !== requested else { return }
        settle()
        guard placeholder !== parent, placeholder.isPristineLeoPlaceholder else { return }
        placeholder.holdSpotForReplacement()
        schedule { [weak placeholder, weak requested] in
            guard let placeholder, let requested, requested.isLeoWindowShown,
                  placeholder.isPristineLeoPlaceholder else { return }
            placeholder.closeReplacedLeoPlaceholder()
        }
    }

    /// From here on the launch window is a window like any other.
    private func settle() {
        let stops = stopObserving
        stopObserving = []
        window = nil
        stops.forEach { $0() }
    }

    nonisolated static func observeLocalInput(_ onInput: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: touchEvents) { event in
            MainActor.assumeIsolated { onInput() }
            return event
        }
        return {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

extension TerminalController: LeoLaunchPlaceholderWindow, LeoRequestedWindow {
    var isPristineLeoPlaceholder: Bool {
        guard let window else { return false }
        return leoIsUnfilledPlaceholder && !leoHasShownContent && surfaceTree.isEmpty && window.attachedSheet == nil
    }

    var isLeoWindowShown: Bool { window?.isVisible == true }

    func observeLeoWindowClose(_ onClose: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        // No window, nothing to watch -- and a nil object would watch every window.
        guard let window else { return {} }
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { _ in
            MainActor.assumeIsolated { onClose() }
        }
        return { NotificationCenter.default.removeObserver(observer) }
    }
}
