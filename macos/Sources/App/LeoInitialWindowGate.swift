/// Decides when launch opens Leo's first window (B-085).
///
/// Upstream opened it on the app's first `applicationDidBecomeActive` only,
/// so a launch that never became active -- `open -g`, a login item, or a
/// launch whose activation macOS 14+ declined because the user clicked
/// another app meanwhile -- showed no window until the user activated Leo.
/// Now the first of two launch events decides, once per launch: the hop
/// `applicationDidFinishLaunching` queues (after AppKit's launch open-file
/// events, so a launch document's window counts) or the first activation,
/// whichever comes first. Later events never open another.
///
/// Only AppKit's default launch (the Dock, Finder, `open`, a login item)
/// opens from the hop. A launch that came to run a script's `make new
/// window`, an App Intent or a Service gets that request after the hop,
/// and the request opens the window it wants: the hop leaves the launch
/// to activation, as upstream did, so no placeholder opens beside it.
struct LeoInitialWindowGate {
    enum Event: Equatable, Sendable {
        /// The main-queue hop queued at the end of `applicationDidFinishLaunching`;
        /// `isDefaultLaunch` is AppKit's `launchIsDefaultUserInfoKey`.
        case didFinishLaunching(isDefaultLaunch: Bool)
        /// The app's first `applicationDidBecomeActive`.
        case didBecomeActive
    }

    /// The event that handled this launch; nil until one has.
    private(set) var handledBy: Event?

    var isLaunchHandled: Bool { handledBy != nil }

    /// Whether `event` should open the first window. The first event of a
    /// launch decides and marks the launch handled -- except a request
    /// launch's hop, which leaves it to activation. It opens a window
    /// unless one already exists (a launch document or a request opened
    /// it) or the config turns `initial-window` off.
    mutating func shouldOpenInitialWindow(on event: Event, windowCount: Int, initialWindow: Bool) -> Bool {
        guard handledBy == nil, event != .didFinishLaunching(isDefaultLaunch: false) else { return false }
        handledBy = event
        return windowCount == 0 && initialWindow
    }

    /// Whether reopen (a Dock or Finder click) should open a window: only
    /// once launch is handled, and only with no terminal window at all --
    /// one may exist but not be visible yet while it sets up.
    func shouldOpenOnReopen(hasVisibleWindows: Bool, windowCount: Int) -> Bool {
        isLaunchHandled && !hasVisibleWindows && windowCount == 0
    }
}
