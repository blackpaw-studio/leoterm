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
/// by its controller for a run-loop pass, by AppKit's close animation, and
/// by AppKit's handling of an opened file, whose blocks keep the app's
/// windows until a timer lets them go about 5 s on. (Leo's own longer hold,
/// the New Tab undo action of a window opened from it, is weak.) Once the
/// window is freed, AppKit can hand its window-server window to a later
/// wait's pool the same way, from the window manager's own callouts. So a
/// closed window has the loop woken until it and its window-server window
/// are gone, for at most `closedWindowWakeLimit`.
enum LeoEventLoop {
    /// The `subtype` of the event `wake(for:)` posts. Its `data1` is the
    /// number of the window it was posted for.
    static let wakeEventSubtype: Int16 = 0x4C57

    /// How often a closed window's loop is woken: how long after its last
    /// owner lets go it may linger.
    static let closedWindowWakeInterval: TimeInterval = 0.5

    /// How long a closed window's loop is woken for: the longest of the
    /// holds above (about 5 s), with as much again to spare. A window held
    /// longer is left to the next event.
    static let closedWindowWakeLimit: TimeInterval = 10

    /// Wakes the event loop every `interval` while `window`, closed, or its
    /// window-server window `windowNumber` lives, for at most `limit`: the
    /// wait after the last owner of either let go ends and is drained,
    /// freeing it. Stops early if `window` is shown again. `windowNumber` is
    /// read before the close, which may give up a one-shot window's number.
    @MainActor static func wakeUntilFreed(
        _ window: NSWindow,
        number windowNumber: Int,
        every interval: TimeInterval = closedWindowWakeInterval,
        for limit: TimeInterval = closedWindowWakeLimit
    ) {
        let deadline = Date(timeIntervalSinceNow: limit)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak window] timer in
            MainActor.assumeIsolated {
                let isShown = window?.isVisible ?? false
                let isGone = window == nil && !windowServerLists(windowNumber)
                guard !isShown, !isGone, Date() < deadline else {
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

    /// Whether the window server still has window `windowNumber`, on screen
    /// or not.
    static func windowServerLists(_ windowNumber: Int) -> Bool {
        guard windowNumber > 0, let id = UnsafeRawPointer(bitPattern: UInt(windowNumber)) else { return false }
        var ids: [UnsafeRawPointer?] = [id]
        let array = ids.withUnsafeMutableBufferPointer { CFArrayCreate(nil, $0.baseAddress, $0.count, nil) }
        guard let array, let infos = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else {
            return false
        }
        return !infos.isEmpty
    }

    /// Ends the event loop's current wait with an application-defined event
    /// nothing handles, so whatever that wait's pool holds goes now.
    /// `windowNumber` is the window it is posted for. While it is handled,
    /// `NSApp.currentEvent` is this event.
    @MainActor static func wake(for windowNumber: Int) {
        guard let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: wakeEventSubtype, data1: windowNumber, data2: 0
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
