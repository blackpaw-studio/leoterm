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
///   `viewHost` keeps every tab's view in a window (E5): the pane shows the
///   active one through it and never adds a view to a window itself.
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
    /// Moves the browser's pages between panes and the parking window.
    var viewHost: LeoAgentBrowserHost { get }
    /// This session's downloads; the pane's strip observes it directly.
    var downloads: LeoBrowserDownloads { get }

    func goBack()
    func goForward()
    func reload()
    /// Loads a user-entered URL (remote terms) in the active tab, opening
    /// the port forward it needs. A failure shows in the page; it doesn't throw.
    func navigate(to url: URL)
    /// Opens a blank tab and makes it active (the toolbar's + button).
    func openBlankTab()
    /// Whether ⌘⇧T has a closed tab to bring back and room to open it.
    var canReopenClosedTab: Bool { get }
    /// Reopens the most recently closed tab at its old place and makes it
    /// active, in the agent's (remote) terms; false (nothing started) when
    /// `canReopenClosedTab` is false. A failed load shows in the page.
    func reopenClosedTab() -> Bool
    /// The active tab's pages behind (`.back`) or ahead (`.forward`), nearest
    /// first, at most `LeoBrowserHistoryEntry.menuLimit`.
    func history(_ direction: LeoBrowserHistoryDirection) -> [LeoBrowserHistoryEntry]
    /// Jumps the active tab to `entry`. False when the history has changed
    /// since the entry was listed (the page at that offset is no longer it).
    func goToHistory(_ entry: LeoBrowserHistoryEntry) -> Bool
    /// The machine and agent this browser belongs to: whose data store Clear
    /// Site Data empties.
    var key: LeoAgentBrowserKey { get }
    /// The active page's address for the system's default browser, through
    /// the machine's port forward for a remote loopback page; nil for no page
    /// or a page that isn't http(s). Throws a `LeoBrowserError` saying why a
    /// remote loopback page can't be reached (B-409).
    func externalURL() async throws -> URL?
    /// Whether a Clear Site Data is under way.
    var isClearingSiteData: Bool { get }
    /// Empties this agent's own data store, and no other agent's. Open pages
    /// aren't reloaded. The caller asks the user first.
    func clearSiteData() async

    func observe(_ handler: @escaping @MainActor () -> Void) -> () -> Void
}

enum LeoBrowserHistoryDirection: Equatable {
    case back, forward
}

/// One page in a tab's back or forward list. `offset` is relative to the
/// current page (-1 is the previous page, 1 the next); `url` is in the
/// agent's (remote) terms.
struct LeoBrowserHistoryEntry: Equatable {
    /// The most entries a history menu lists.
    static let menuLimit = 20

    let offset: Int
    let title: String
    let url: URL

    var direction: LeoBrowserHistoryDirection { offset < 0 ? .back : .forward }
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
/// the agent's data store. `openBrowser` (the row's Open Browser) is the one
/// way the UI makes a browser: it returns the existing one or makes one,
/// opening a blank tab when it has none, and nil when this Mac can't run one.
@MainActor
protocol LeoAgentBrowserPresence: AnyObject {
    var keys: Set<LeoAgentBrowserKey> { get }
    func browser(for key: LeoAgentBrowserKey) -> (any LeoAgentBrowserPaneSource)?
    func openBrowser(for key: LeoAgentBrowserKey) -> (any LeoAgentBrowserPaneSource)?
    func closeBrowser(for key: LeoAgentBrowserKey)
    func observe(_ handler: @escaping @MainActor (LeoAgentBrowserPresenceChange) -> Void) -> () -> Void
}

extension LeoAgentBrowserPresence {
    func hasBrowser(for key: LeoAgentBrowserKey) -> Bool { keys.contains(key) }
}
