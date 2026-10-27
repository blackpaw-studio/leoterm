import Foundation

/// Limits an agent browser enforces.
public enum LeoBrowserLimits {
    /// The most tabs one agent browser holds; `tab_new` and popups beyond it fail with `tab_limit`.
    public static let maximumTabs = 10
}

/// One row of `browser_tabs`.
public struct LeoBrowserTabInfo: Equatable, Sendable {
    public let id: Int
    /// In the web view's own (local) terms; the executor maps it to remote terms.
    public let url: URL?
    public let title: String
    public let isActive: Bool

    public init(id: Int, url: URL?, title: String, isActive: Bool) {
        self.id = id
        self.url = url
        self.title = title
        self.isActive = isActive
    }
}

/// An agent browser's tab set. Ids are stable for a tab's life and never
/// reused within a browser. The executor checks existence and the tab cap
/// before it calls `selectTab` / `closeTab` / `openTab`, so those don't throw
/// for either.
@MainActor
public protocol LeoBrowserTabs: AnyObject {
    /// Every tab, in order, with the active one flagged.
    var tabs: [LeoBrowserTabInfo] { get }

    /// The page for `id`, or the active tab's when nil; nil when there is no such
    /// tab (or no tab at all).
    func page(forTab id: Int?) -> (any LeoBrowserPage)?

    /// Opens a tab, makes it active and loads `url` (`about:blank` for a blank
    /// tab), returning its id once the load finishes. `url` is already in local terms.
    func openTab(url: URL) async throws -> Int

    func selectTab(_ id: Int)

    /// Closes a tab; when it was active, the browser picks another active tab.
    func closeTab(_ id: Int)
}
