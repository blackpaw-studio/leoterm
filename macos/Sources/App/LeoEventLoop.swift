import AppKit

/// AppKit's event loop (`-[NSApplication run]`) waits for each event inside
/// an autorelease pool that it drains only once that event has been handled,
/// and every wait starts by autoreleasing each of the app's windows
/// (`nextEventMatchingMask` copies `NSApp.windows` for its gesture
/// recognizers). A window whose last owner lets go of it during a wait --
/// its controller, freed a run-loop pass after the window closed -- lives on
/// in that pool, off screen yet in `NSApp.windows` and the window server's
/// list, until the next event: in an idle app, the user's next key press or
/// click (B-143).
enum LeoEventLoop {
    /// The `subtype` of the event `wake()` posts.
    static let wakeEventSubtype: Int16 = 0x4C57

    /// Ends the event loop's current wait with an application-defined event
    /// nothing handles, so whatever that wait's pool holds goes now. Safe
    /// from any thread, a `deinit` included: it posts from the main queue,
    /// which the wait in progress runs.
    nonisolated static func wakeSoon() {
        DispatchQueue.main.async { MainActor.assumeIsolated { wake() } }
    }

    @MainActor static func wake() {
        guard let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: wakeEventSubtype, data1: 0, data2: 0
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
