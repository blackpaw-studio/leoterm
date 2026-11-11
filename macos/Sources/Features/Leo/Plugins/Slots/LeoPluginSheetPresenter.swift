import AppKit
import SwiftUI

/// Shows a SwiftUI view as a sheet on a window and waits for its answer.
/// The view calls the `finish` it is given exactly once (a second call is
/// ignored), which closes the sheet and returns the value.
struct LeoPluginSheetPresenter {
    /// The window to hang a sheet on: the key window, else the main window.
    var hostWindow: @MainActor () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }

    /// Nil if there is no window to present on (nothing is shown, so nothing
    /// can be confirmed): callers treat it as a cancel.
    @MainActor func present<Value, Content: View>(
        _ content: (@escaping (Value) -> Void) -> Content
    ) async -> Value? {
        guard let parent = hostWindow() else { return nil }
        return await withCheckedContinuation { continuation in
            var sheet: NSWindow?
            var isDone = false
            let finish: (Value?) -> Void = { value in
                guard !isDone else { return }
                isDone = true
                if let sheet { parent.endSheet(sheet) }
                continuation.resume(returning: value)
            }
            let controller = NSHostingController(rootView: content { finish($0) })
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled]
            sheet = window
            parent.beginSheet(window)
        }
    }

    /// A sheet with only a cancel path (Escape, Cancel button): `finish(nil)` is the cancel.
    @MainActor func presentCancellable<Value, Content: View>(
        _ content: (@escaping (Value?) -> Void) -> Content
    ) async -> Value? {
        guard let parent = hostWindow() else { return nil }
        return await withCheckedContinuation { continuation in
            var sheet: NSWindow?
            var isDone = false
            let finish: (Value?) -> Void = { value in
                guard !isDone else { return }
                isDone = true
                if let sheet { parent.endSheet(sheet) }
                continuation.resume(returning: value)
            }
            let controller = NSHostingController(rootView: content(finish))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled]
            sheet = window
            parent.beginSheet(window)
        }
    }
}
