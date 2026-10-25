import AppKit

extension TerminalController {
    /// B-075: a window going on screen starts with its focus in the content
    /// area, never in the sidebar's search field.
    ///
    /// Without an `initialFirstResponder`, AppKit makes the first view of
    /// the key view loop first responder when the window is first ordered
    /// in. The start screen has nothing focusable, so the search field at
    /// the sidebar's top-left won. Naming the content view (which refuses
    /// first responder) skips that pick: the window itself keeps the first
    /// responder, as a Finder window with no selection does, and
    /// `windowDidBecomeKey` hands it to the focused terminal when there is
    /// one. ⌥⌘F (Agents ▸ Find Agent…) is how you reach the search field.
    func leoLeaveInitialFocusToContent(_ content: NSView) {
        window?.initialFirstResponder = content
    }

    /// Skipping AppKit's first pick also skips the key view loop it builds
    /// alongside it (the nibs turn off `autorecalculatesKeyViewLoop`), so
    /// Tab from the start screen reached nothing. The loop is rebuilt each
    /// time the window becomes key, on the next turn. Ordering the window
    /// in builds the sidebar, so its search field is in the loop at launch
    /// (`LeoLaunchFocusTests`); the turn is margin. This never moves the
    /// first responder. It is rebuilt only then, and a sidebar or pane shown
    /// or hidden while the window stays key needs no rebuild (B-157): the
    /// loop keeps collapsed panes' views and Tab skips them while hidden
    /// (`LeoLaunchFocusTests`). Only a view created after the rebuild is
    /// missing until the window is next key.
    func leoRebuildKeyViewLoop() {
        DispatchQueue.main.async { [weak self] in
            self?.window?.recalculateKeyViewLoop()
        }
    }
}
