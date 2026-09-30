import AppKit

/// What `LeoLaunchPlaceholder` needs from the window a launch opened.
@MainActor
protocol LeoLaunchPlaceholderWindow: AnyObject {
    /// Still the empty start screen it opened with, never having shown an
    /// agent or a terminal.
    var isPristineLeoPlaceholder: Bool { get }
    /// The next window to cascade lands on this window's spot.
    func holdSpotForReplacement()
    /// Closes it for good (no confirmation, nothing to undo), still holding
    /// its spot for the window replacing it.
    func closeReplacedLeoPlaceholder()
}

/// The empty window a launch opened on its own (B-085) gives way to the
/// first window something asks for -- a script's `make new window`, an App
/// Intent, a Service, an opened file, a notification -- as an untouched
/// untitled document does in a document app. A cold launch those start
/// then ends with one window, whether or not AppKit counted it as a
/// default launch. The launch window stays for good once the user touches
/// Leo (a key or mouse press anywhere in the app) or it shows anything,
/// so a window opened from its own buttons or rows never replaces it.
@MainActor
final class LeoLaunchPlaceholder {
    private weak var window: (any LeoLaunchPlaceholderWindow)?
    private var stopObservingInput: (() -> Void)?
    private let observeUserInput: (@escaping @MainActor () -> Void) -> () -> Void
    private let schedule: (@escaping @MainActor () -> Void) -> Void

    /// `observeUserInput` calls its argument on the user's first key or
    /// mouse press and returns a function that stops observing.
    init(
        observeUserInput: @escaping (@escaping @MainActor () -> Void) -> () -> Void = LeoLaunchPlaceholder.observeLocalInput,
        schedule: @escaping (@escaping @MainActor () -> Void) -> Void = LeoInitialWindowOpener.onNextMainQueueTurn
    ) {
        self.observeUserInput = observeUserInput
        self.schedule = schedule
    }

    /// The launch opened `window` for nobody in particular.
    func adopt(_ window: any LeoLaunchPlaceholderWindow) {
        settle()
        self.window = window
        stopObservingInput = observeUserInput { [weak self] in self?.settle() }
    }

    /// `requested` just opened. A pristine launch window gives way to it:
    /// `requested` cascades onto its spot, and it closes once `requested`
    /// has shown (that presentation is already on the main queue), so the
    /// window never jumps and there is never none.
    func windowDidOpen(_ requested: AnyObject) {
        guard let placeholder = window, placeholder !== requested else { return }
        settle()
        guard placeholder.isPristineLeoPlaceholder else { return }
        placeholder.holdSpotForReplacement()
        schedule { [weak placeholder] in
            guard let placeholder, placeholder.isPristineLeoPlaceholder else { return }
            placeholder.closeReplacedLeoPlaceholder()
        }
    }

    /// From here on the launch window is a window like any other.
    private func settle() {
        stopObservingInput?()
        stopObservingInput = nil
        window = nil
    }

    nonisolated static func observeLocalInput(_ onInput: @escaping @MainActor () -> Void) -> () -> Void {
        let monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            MainActor.assumeIsolated { onInput() }
            return event
        }
        return {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

extension TerminalController: LeoLaunchPlaceholderWindow {
    var isPristineLeoPlaceholder: Bool {
        leoIsUnfilledPlaceholder && !leoHasShownContent && surfaceTree.isEmpty
    }
}
