import Foundation

/// A browser-tool failure the agent sees as `{ok:false, error:{code, message}}`.
public struct LeoBrowserError: Error, Equatable, Sendable {
    public enum Code: String, CaseIterable, Sendable {
        case userHasControl = "user_has_control"
        case staleRef = "stale_ref"
        case tabLimit = "tab_limit"
        case schemeNotAllowed = "scheme_not_allowed"
        case navigationFailed = "navigation_failed"
        case timeout
        case jsError = "js_error"
        case invalidArgs = "invalid_args"
        case noSuchTab = "no_such_tab"
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var clientToolError: LeoClientToolError { LeoClientToolError(code: code.rawValue, message: message) }

    public static let userHasControl = LeoBrowserError(
        .userHasControl, "The user has control of the browser; wait or call browser_handoff"
    )

    public static func invalidArgs(_ message: String) -> Self { Self(.invalidArgs, message) }
    public static func staleRef(_ ref: String) -> Self { Self(.staleRef, "ref \(ref) is not in the current snapshot; call browser_snapshot again") }
    public static func noSuchTab(_ tab: Int) -> Self { Self(.noSuchTab, "No tab with id \(tab)") }
    public static func tabLimit(_ limit: Int) -> Self { Self(.tabLimit, "The browser already has \(limit) tabs; close one first") }
}
