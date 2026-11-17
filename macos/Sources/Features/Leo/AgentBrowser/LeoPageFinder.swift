import AppKit
import WebKit

/// Where the find bar stands: the 1-based current match (0 for none), how
/// many matches there are, and whether counting stopped at the limit.
struct LeoFindResult: Equatable, Sendable {
    let index: Int
    let total: Int
    let isCapped: Bool

    static let none = LeoFindResult(index: 0, total: 0, isCapped: false)
}

enum LeoFindDirection: String, Sendable {
    case next, previous
}

/// Finds text in a browser tab's page. Every call names the view it acts
/// on; a view that is not a page (or none) answers `.none` and does nothing.
@MainActor
protocol LeoPageFinding: AnyObject {
    /// Counts the matches of `query` and marks them, keeping the current
    /// match when the query is unchanged and starting at the first otherwise.
    func search(_ query: String, in view: NSView?) async -> LeoFindResult
    /// Moves the current match one step, wrapping at the ends.
    func step(_ direction: LeoFindDirection, query: String, in view: NSView?) async -> LeoFindResult
    /// Removes every mark.
    func clear(in view: NSView?) async
    /// The text selected in the page, for Edit ▸ Use Selection for Find.
    func selectedText(in view: NSView?) async -> String?
}

/// Runs `LeoBrowserFindScript` in a content world of its own, on the main
/// frame. Finding is reading the page, so it is not user input.
@MainActor
final class LeoWKPageFinder: LeoPageFinding {
    static let world = WKContentWorld.world(name: "LeoFind")

    /// Stateless, so a default argument can make one off the main actor.
    nonisolated init() {}

    func search(_ query: String, in view: NSView?) async -> LeoFindResult {
        await run("search", query, in: view)
    }

    func step(_ direction: LeoFindDirection, query: String, in view: NSView?) async -> LeoFindResult {
        await run(direction.rawValue, query, in: view)
    }

    func clear(in view: NSView?) async {
        _ = await run("clear", "", in: view)
    }

    func selectedText(in view: NSView?) async -> String? {
        guard let webView = view as? WKWebView else { return nil }
        let text = try? await webView.callAsyncJavaScript(
            LeoBrowserFindScript.body, arguments: ["action": "selection", "query": ""], in: nil, contentWorld: Self.world) as? String
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func run(_ action: String, _ query: String, in view: NSView?) async -> LeoFindResult {
        guard let webView = view as? WKWebView else { return .none }
        let reply = try? await webView.callAsyncJavaScript(
            LeoBrowserFindScript.body, arguments: ["action": action, "query": query], in: nil, contentWorld: Self.world)
        return Self.result(from: reply) ?? .none
    }

    nonisolated static func result(from reply: Any?) -> LeoFindResult? {
        guard let dictionary = reply as? [String: Any],
              let index = (dictionary["index"] as? NSNumber)?.intValue,
              let total = (dictionary["total"] as? NSNumber)?.intValue else { return nil }
        return LeoFindResult(index: index, total: total, isCapped: (dictionary["capped"] as? NSNumber)?.boolValue ?? false)
    }
}
