import AppKit

/// AppKit's event loop (`-[NSApplication run]`) waits for each event inside
/// an autorelease pool that it drains only once that event has been handled,
/// and every wait starts by autoreleasing each of the app's windows
/// (`nextEventMatchingMask` copies `NSApp.windows` for its gesture
/// recognizers). A closed window whose last owner lets go of it during a
/// wait -- from a timer, a run-loop block or a main-queue turn, not an
/// event -- lives on in that pool, off screen yet in `NSApp.windows` and the
/// window server's list, until the next event: in an idle app, the user's
/// next key press or click (B-143).
///
/// Who lets go last isn't Leo's to decide. A closed terminal window is held
/// by its controller for a run-loop pass, by AppKit's close animation, by
/// AppKit's handling of an opened file, and by the New Tab undo action of a
/// window opened from it (redo opens the tab from it again) until that
/// action expires. So a closed window has the loop woken until it is freed.
enum LeoEventLoop {
    /// The `subtype` of the event `wake(for:)` posts. Its `data1` is the
    /// number of the window it was posted for.
    static let wakeEventSubtype: Int16 = 0x4C57

    /// How often a closed window's loop is woken: how long after its last
    /// owner lets go it may linger.
    static let closedWindowWakeInterval: TimeInterval = 0.5

    /// How long a closed window's loop is woken for: the longest of the
    /// holds above, the default undo timeout (5 s), with as much again to
    /// spare. A window held longer (a longer `undo-timeout`) is left to the
    /// next event.
    static let closedWindowWakeLimit: TimeInterval = 10

    /// Wakes the event loop every `interval` while `window`, closed, lives,
    /// for at most `limit`: the wait after its last owner let go of it ends
    /// and is drained, freeing it.
    @MainActor static func wakeUntilFreed(
        _ window: NSWindow,
        every interval: TimeInterval = closedWindowWakeInterval,
        for limit: TimeInterval = closedWindowWakeLimit
    ) {
        let deadline = Date(timeIntervalSinceNow: limit)
        let windowNumber = window.windowNumber
        let timer = Timer(timeInterval: interval, repeats: true) { [weak window] timer in
            MainActor.assumeIsolated {
                guard window != nil, Date() < deadline else {
                    timer.invalidate()
                    return
                }
                wake(for: windowNumber)
            }
        }
        timer.tolerance = interval / 2
        // The mode `-[NSApplication run]` waits in.
        RunLoop.main.add(timer, forMode: .default)
    }

    /// Ends the event loop's current wait with an application-defined event
    /// nothing handles, so whatever that wait's pool holds goes now.
    /// `windowNumber` is the window it is posted for.
    @MainActor static func wake(for windowNumber: Int) {
        guard let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: wakeEventSubtype, data1: windowNumber, data2: 0
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
