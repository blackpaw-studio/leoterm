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
    /// first responder.
    ///
    /// Showing or hiding a sidebar or pane that already has its views needs
    /// no rebuild while the window stays key (B-157): the loop keeps a
    /// collapsed pane's views and Tab skips them while hidden. A view made
    /// after the last rebuild is the exception, so whatever makes one asks
    /// for a rebuild itself (`NSWindow.leoRebuildKeyViewLoop`): a row's
    /// pane shown for the first time (`LeoRowPaneContainerViewController`).
    func leoRebuildKeyViewLoop() {
        window?.leoRebuildKeyViewLoop()
    }
}

extension NSWindow {
    /// Rebuilds the key view loop on the next turn, so a view made in this
    /// one is in it. Idempotent and safe on a window that isn't key.
    func leoRebuildKeyViewLoop() {
        DispatchQueue.main.async { [weak self] in
            self?.recalculateKeyViewLoop()
        }
    }
}
