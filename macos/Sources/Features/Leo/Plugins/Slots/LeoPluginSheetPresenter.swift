import AppKit
import SwiftUI

/// Shows a SwiftUI view as a sheet on a window and waits for its answer.
/// The view calls the `finish` it is given exactly once (a second call is
/// ignored), which closes the sheet and returns the value. The sheet also
/// ends, as a cancel, if either window closes or the awaiting task is
/// cancelled, so a caller is never left waiting on a sheet nobody can answer.
struct LeoPluginSheetPresenter {
    /// The window to hang a sheet on: the key window, else the main window.
    var hostWindow: @MainActor () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }

    /// Nil if there is no window to present on (nothing is shown, so nothing
    /// can be confirmed): callers treat it as a cancel.
    @MainActor func present<Value, Content: View>(
        _ content: (@escaping (Value) -> Void) -> Content
    ) async -> Value? {
        await presentCancellable { finish in content { finish($0) } }
    }

    /// A sheet with only a cancel path (Escape, Cancel button): `finish(nil)` is the cancel.
    @MainActor func presentCancellable<Value, Content: View>(
        _ content: (@escaping (Value?) -> Void) -> Content
    ) async -> Value? {
        guard !Task.isCancelled, let parent = hostWindow() else { return nil }
        let rendezvous = LeoPluginSheetRendezvous<Value>()
        let finish: (Value?) -> Void = { rendezvous.finish($0) }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content(finish)))
        window.styleMask = [.titled]

        let observers = [parent, window].map { watched in
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: watched, queue: .main) { _ in
                MainActor.assumeIsolated { rendezvous.finish(nil) }
            }
        }
        rendezvous.onFinish {
            observers.forEach(NotificationCenter.default.removeObserver)
            parent.endSheet(window)
        }
        parent.beginSheet(window, completionHandler: nil)
        return await rendezvous.wait()
    }
}
