import AppKit
import LeoKit

/// Names one agent's browser: the machine it runs on and the agent's name as
/// the daemon knows it. A dispatch child is named `dispatch:<id>` (its
/// `LEO_PROCESS_NAME`), so each dispatch has its own browser.
struct LeoAgentBrowserKey: Hashable, Sendable {
    let host: LeoHostID
    let agent: String

    static func dispatch(host: LeoHostID, id: String) -> Self {
        Self(host: host, agent: "dispatch:\(id)")
    }
}

/// What the browser pane needs from an agent browser. The browser model
/// (`LeoAgentBrowser`, C5) conforms; the pane never sees WebKit types beyond
/// the view it hosts. Everything runs on the main actor.
///
/// Contract for conformers:
/// - `observe` handlers run after each change to anything a getter returns
///   (tabs, active tab, URL, title, loading, history) -- not for control
///   changes, which `control.observe` reports. Calling the returned closure
///   removes the handler. Handlers may be called more often than needed.
/// - `activeView` is the active tab's web view, or nil before the first tab.
///   Hosting it (E5) is the pane's job; the source must not add it to a window.
/// - `activeRemoteURL` is the active tab's URL in the agent's (remote) terms,
///   already mapped back through `LeoBrowserURLMapping.toRemote`.
/// - The user actions below come from the user's own clicks. The pane reports
///   user input to `control` itself before calling them, so they are not gated
///   on `control` and must work whoever is driving.
@MainActor
protocol LeoAgentBrowserPaneSource: AnyObject {
    var tabs: any LeoBrowserTabs { get }
    var control: LeoBrowserControlModel { get }
    var activeView: NSView? { get }
    var activeRemoteURL: URL? { get }
    var isLoading: Bool { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }

    func goBack()
    func goForward()
    func reload()
    /// Loads a user-entered URL (remote terms) in the active tab, opening
    /// the port forward it needs. A failure shows in the page; it doesn't throw.
    func navigate(to url: URL)
    /// Opens a blank tab and makes it active (the toolbar's + button).
    func openBlankTab()

    func observe(_ handler: @escaping @MainActor () -> Void) -> () -> Void
}

enum LeoAgentBrowserPresenceChange: Equatable {
    case opened(LeoAgentBrowserKey)
    case closed(LeoAgentBrowserKey)
}

/// Which agent browsers exist. The app-level registry (`LeoAgentBrowsers`,
/// C5) conforms. The sidebar badge, the row pane's auto-open and the handoff
/// notifier read it; none of them creates a browser.
///
/// Contract for conformers: `observe` handlers run on the main actor after
/// the registry changed, `.opened` once per new browser (never for a browser
/// that already exists), `.closed` once when it goes (the agent stopped, or
/// `closeBrowser`). `closeBrowser` for an unknown key does nothing; it keeps
/// the agent's data store.
@MainActor
protocol LeoAgentBrowserPresence: AnyObject {
    var keys: Set<LeoAgentBrowserKey> { get }
    func browser(for key: LeoAgentBrowserKey) -> (any LeoAgentBrowserPaneSource)?
    func closeBrowser(for key: LeoAgentBrowserKey)
    func observe(_ handler: @escaping @MainActor (LeoAgentBrowserPresenceChange) -> Void) -> () -> Void
}

extension LeoAgentBrowserPresence {
    func hasBrowser(for key: LeoAgentBrowserKey) -> Bool { keys.contains(key) }
}
