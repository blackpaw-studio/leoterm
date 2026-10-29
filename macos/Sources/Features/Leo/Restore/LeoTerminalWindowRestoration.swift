import AppKit
import OSLog

/// B-332: AppKit restores a Leo window through this class at launch, as
/// Ghostty restores its windows (`TerminalWindowRestoration`, which Leo
/// keeps answering with no window for state saved before Leo): its
/// Terminals rows come back from `LeoTerminalsRestorableState`, each a
/// fresh shell in its saved layout. Whether AppKit restores at all is
/// `window-save-state`'s call, as upstream: `AppDelegate` sets
/// `NSQuitAlwaysKeepsWindows` from it, and `never` restores nothing here
/// even after a crash.
final class LeoTerminalWindowRestoration: NSObject, NSWindowRestoration {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    static let identifier = NSUserInterfaceItemIdentifier("LeoTerminalWindowRestoration")

    /// Leo windows save state for restoring, except in an XCTest host:
    /// its windows are the debug app's, so a test's would come back the
    /// next time that app launches.
    static let isEnabled = !LeoSingleInstance.isRunningAsTestHost()

    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        guard identifier == Self.identifier else { return completionHandler(nil, TerminalRestoreError.identifierUnknown) }
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return completionHandler(nil, TerminalRestoreError.delegateInvalid) }
        guard isEnabled else { return completionHandler(nil, nil) }
        MainActor.assumeIsolated {
            // `ghostty.config` directly is safe: restoration only runs at
            // launch, before any config reload.
            let (window, error) = restore(from: state, windowSaveState: appDelegate.ghostty.config.windowSaveState) {
                openWindow(restoring: $0, appDelegate: appDelegate)
            }
            completionHandler(window, error)
        }
    }

    /// Decodes `coder`'s rows -- unless `windowSaveState` is `never`,
    /// which decodes nothing (decoding starts the shells) -- and `open`s a
    /// window with them. No window when there are no rows: launch then
    /// shows the start screen.
    @MainActor static func restore(
        from coder: NSCoder,
        windowSaveState: String,
        open: (LeoTerminalsRestorableState) -> NSWindow?
    ) -> (NSWindow?, Error?) {
        guard windowSaveState != "never" else {
            logger.log("skip restoration: window-save-state=never")
            return (nil, nil)
        }
        guard let state = LeoTerminalsRestorableState(coder: coder) else { return (nil, TerminalRestoreError.stateDecodeFailed) }
        guard !state.rows.isEmpty else { return (nil, nil) }
        guard let window = open(state) else { return (nil, TerminalRestoreError.windowDidNotLoad) }
        logger.log("restored a window with \(state.rows.count) terminal rows")
        return (window, nil)
    }

    /// A start screen's window, built as AppKit's own restoration builds
    /// one -- not shown, cascaded or sized here: AppKit puts it back in
    /// its saved frame and order -- with `state`'s rows. Closed again if
    /// none could be restored, so it holds no launch window off.
    @MainActor private static func openWindow(restoring state: LeoTerminalsRestorableState, appDelegate: AppDelegate) -> NSWindow? {
        let controller = TerminalController(appDelegate.ghostty, withSurfaceTree: .init(), leoIsPlaceholder: true)
        guard let window = controller.window else { return nil }
        guard appDelegate.leoRuntime.restoreTerminalRows(state, in: controller) else {
            window.close()
            return nil
        }
        return window
    }
}
