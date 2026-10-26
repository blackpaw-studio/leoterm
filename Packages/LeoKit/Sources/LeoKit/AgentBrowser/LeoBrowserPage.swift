import Foundation

/// One console message a page logged.
public struct LeoBrowserConsoleEntry: Equatable, Sendable {
    /// `log`, `info`, `warn`, `error`, `debug`, or `exception` for an uncaught
    /// error or unhandled rejection.
    public let level: String
    public let text: String

    public init(level: String, text: String) {
        self.level = level
        self.text = text
    }
}

/// Console messages plus the cursor to pass as `since` to continue after them.
public struct LeoBrowserConsoleBatch: Equatable, Sendable {
    public let entries: [LeoBrowserConsoleEntry]
    public let cursor: Int

    public init(entries: [LeoBrowserConsoleEntry], cursor: Int) {
        self.entries = entries
        self.cursor = cursor
    }
}

/// One browser tab as the executor drives it: a page that loads URLs, reads
/// itself and takes input. WebKit-agnostic; the Mac app conforms with a
/// `WKWebView` adapter and tests conform with a fake.
///
/// Every method runs on the main actor. Errors: throw `LeoBrowserError` for
/// the codes the agent should see (`stale_ref`, `navigation_failed`, `timeout`,
/// `js_error`); any other error is reported with a generic code. Long
/// operations must honour task cancellation (the daemon cancels a call when
/// its timeout elapses).
@MainActor
public protocol LeoBrowserPage: AnyObject {
    /// The URL the page is showing, in the web view's own (local) terms.
    var url: URL? { get }

    /// The page title; empty when it has none.
    var title: String { get }

    /// Loads `url` and returns once the load finishes. Throws `navigation_failed`
    /// on a load error and `timeout` when the load does not finish in time.
    func load(_ url: URL) async throws

    /// History navigation; each waits for the load like `load`. Throws
    /// `navigation_failed` when there is nothing to go back or forward to.
    func goBack() async throws
    func goForward() async throws
    func reload() async throws

    /// A text tree of the page: role, accessible name, value and a `ref` on each
    /// visible interactive element, already truncated at 50 000 characters with
    /// a note. Issues a fresh ref set; refs from earlier snapshots go stale.
    func snapshot() async throws -> String

    /// Scrolls the element for `ref` into view and clicks it with real input
    /// events. Throws `stale_ref` when the ref is not in the current snapshot.
    func click(ref: String) async throws

    /// Focuses the element for `ref` and types `text` with real key events,
    /// then presses Enter when `submit` is true. Throws `stale_ref` like `click`.
    func type(ref: String, text: String, submit: Bool) async throws

    /// Presses a key or chord on the focused element.
    func press(_ combo: LeoBrowserKeyCombo) async throws

    /// PNG data, at most 1600 px wide; `fullPage` captures the whole scroll height.
    func screenshot(fullPage: Bool) async throws -> Data

    /// Returns once `text` appears in the page's visible text; throws `timeout`
    /// after `timeoutMilliseconds`.
    func waitForText(_ text: String, timeoutMilliseconds: Int) async throws

    /// Evaluates JavaScript in the page world and returns the JSON-serialised
    /// result. Throws `js_error` when the script throws.
    func evaluate(_ js: String) async throws -> String

    /// Console messages after `since`, or since the previous call when nil. The
    /// page keeps the last 500 messages and the cursor counts every message ever
    /// seen, so it only grows.
    func consoleMessages(since: Int?) -> LeoBrowserConsoleBatch
}
