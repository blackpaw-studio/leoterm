import AppKit
import OSLog

/// Wires `LeoInitialWindowGate` to the app's launch, activation and reopen
/// callbacks (B-085): all three consult this one gate. The app's window
/// count, `initial-window` and the window factory are injected, as is the
/// main-queue hop, so tests can run the hop when they choose.
@MainActor
final class LeoInitialWindowOpener {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    private var gate = LeoInitialWindowGate()
    private let windowCount: @MainActor () -> Int
    private let initialWindow: @MainActor () -> Bool
    private let openWindow: @MainActor () -> Void
    private let schedule: (@escaping @MainActor () -> Void) -> Void

    init(
        windowCount: @escaping @MainActor () -> Int,
        initialWindow: @escaping @MainActor () -> Bool,
        openWindow: @escaping @MainActor () -> Void,
        schedule: @escaping (@escaping @MainActor () -> Void) -> Void = LeoInitialWindowOpener.onNextMainQueueTurn
    ) {
        self.windowCount = windowCount
        self.initialWindow = initialWindow
        self.openWindow = openWindow
        self.schedule = schedule
    }

    /// AppKit's `launchIsDefaultUserInfoKey` from the did-finish-launching
    /// notification: false when the launch came to open a file, perform a
    /// Service or run a script. Assumed true when absent, so a launch is
    /// never left without a window on a missing key (P1).
    nonisolated static func isDefaultLaunch(userInfo: [AnyHashable: Any]?) -> Bool {
        (userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? NSNumber)?.boolValue ?? true
    }

    /// Call at the end of `applicationDidFinishLaunching`: queues the launch
    /// hop, which runs after AppKit's launch open-file events.
    func didFinishLaunching(isDefaultLaunch: Bool) {
        Self.logger.log("launch isDefault=\(isDefaultLaunch, privacy: .public)")
        schedule { [weak self] in
            self?.openIfNeeded(on: .didFinishLaunching(isDefaultLaunch: isDefaultLaunch))
        }
    }

    func didBecomeActive() {
        openIfNeeded(on: .didBecomeActive)
    }

    /// Whether reopen should open a window; the caller opens it.
    func shouldOpenOnReopen(hasVisibleWindows: Bool) -> Bool {
        gate.shouldOpenOnReopen(hasVisibleWindows: hasVisibleWindows, windowCount: windowCount())
    }

    private func openIfNeeded(on event: LeoInitialWindowGate.Event) {
        let shouldOpen = gate.shouldOpenInitialWindow(on: event, windowCount: windowCount(), initialWindow: initialWindow())
        guard shouldOpen else { return }
        Self.logger.log("opening the initial window on \(String(describing: event), privacy: .public)")
        openWindow()
    }

    nonisolated static func onNextMainQueueTurn(_ block: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { block() } }
    }
}
