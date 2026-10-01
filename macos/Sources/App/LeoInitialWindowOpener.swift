import Foundation
import OSLog

/// Wires `LeoInitialWindowGate` to the app's launch, activation and reopen
/// callbacks (B-085): all three consult this one gate. The app's window
/// count, `initial-window` and the window factories (launch's and
/// reopen's) are injected, as is the main-queue hop, so tests can run the
/// hop when they choose.
@MainActor
final class LeoInitialWindowOpener {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    private var gate = LeoInitialWindowGate()
    private let windowCount: @MainActor () -> Int
    private let initialWindow: @MainActor () -> Bool
    private let openWindow: @MainActor () -> Void
    private let openOnReopen: @MainActor () -> Void
    private let schedule: (@escaping @MainActor @Sendable () -> Void) -> Void

    init(
        windowCount: @escaping @MainActor () -> Int,
        initialWindow: @escaping @MainActor () -> Bool,
        openWindow: @escaping @MainActor () -> Void,
        openOnReopen: @escaping @MainActor () -> Void,
        schedule: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void = LeoInitialWindowOpener.onNextMainQueueTurn
    ) {
        self.windowCount = windowCount
        self.initialWindow = initialWindow
        self.openWindow = openWindow
        self.openOnReopen = openOnReopen
        self.schedule = schedule
    }

    /// Call at the end of `applicationDidFinishLaunching`: queues the launch
    /// hop, which runs after AppKit's launch open-file events.
    func didFinishLaunching() {
        schedule { [weak self] in
            self?.openIfNeeded(on: .didFinishLaunching)
        }
    }

    func didBecomeActive() {
        openIfNeeded(on: .didBecomeActive)
    }

    /// Whether reopen should open a window.
    func shouldOpenOnReopen(hasVisibleWindows: Bool) -> Bool {
        gate.shouldOpenOnReopen(hasVisibleWindows: hasVisibleWindows, windowCount: windowCount())
    }

    /// `applicationShouldHandleReopen`: opens reopen's window when the gate
    /// says so (B-095) and returns false, AppKit's "handled"; otherwise
    /// opens nothing and returns true, leaving AppKit its default.
    func reopen(hasVisibleWindows: Bool) -> Bool {
        guard shouldOpenOnReopen(hasVisibleWindows: hasVisibleWindows) else { return true }
        openOnReopen()
        return false
    }

    private func openIfNeeded(on event: LeoInitialWindowGate.Event) {
        let shouldOpen = gate.shouldOpenInitialWindow(on: event, windowCount: windowCount(), initialWindow: initialWindow())
        guard shouldOpen else { return }
        Self.logger.log("opening the initial window on \(String(describing: event), privacy: .public)")
        openWindow()
    }

    nonisolated static func onNextMainQueueTurn(_ block: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { block() } }
    }
}
