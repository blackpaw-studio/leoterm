import Foundation

/// A tab the user (or the agent) closed, kept so ⌘⇧T can bring it back.
public struct LeoClosedTab: Equatable, Sendable {
    /// The page's URL in the web view's own (local) terms.
    public let url: URL?
    /// Where the tab sat in the strip.
    public let index: Int
    /// The tab's user-agent override, if it had one.
    public let userAgent: String?

    public init(url: URL?, index: Int, userAgent: String?) {
        self.url = url
        self.index = index
        self.userAgent = userAgent
    }
}

/// One agent browser's recently closed tabs, newest last. Tabs without a
/// real page (no URL, `about:blank`) are not worth reopening and are skipped.
public struct LeoBrowserClosedTabs: Equatable, Sendable {
    /// The most closed tabs remembered; older ones drop off.
    public static let capacity = 20

    private var stack: [LeoClosedTab] = []

    public init() {}

    public var isEmpty: Bool { stack.isEmpty }
    public var count: Int { stack.count }

    public mutating func record(_ tab: LeoClosedTab) {
        guard let url = tab.url, url.absoluteString != "about:blank" else { return }
        stack.append(tab)
        if stack.count > Self.capacity { stack.removeFirst(stack.count - Self.capacity) }
    }

    /// The most recently closed tab, removed.
    public mutating func popLast() -> LeoClosedTab? { stack.popLast() }
}
