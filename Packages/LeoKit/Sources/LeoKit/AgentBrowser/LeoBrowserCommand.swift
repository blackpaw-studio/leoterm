import Foundation

/// What a browser tool asks for, decoded from the tool name and its JSON args.
public struct LeoBrowserCommand: Equatable, Sendable {
    /// The tab to act on; nil means the active tab. Always nil for the tools
    /// with no `tab` argument and for `tab_select` / `tab_close`, whose target
    /// lives in the action.
    public let tab: Int?
    public let action: LeoBrowserAction

    public init(tab: Int?, action: LeoBrowserAction) {
        self.tab = tab
        self.action = action
    }

    /// Throws `invalid_args` for an unknown tool, a missing or mistyped argument,
    /// or a value out of range.
    public init(tool: String, args: LeoJSONValue) throws {
        let reader = try LeoBrowserArgs(args)
        switch tool {
        case "browser_navigate":
            self.init(tab: try reader.tab(), action: .navigate(url: try reader.requiredString("url")))
        case "browser_back":
            self.init(tab: try reader.tab(), action: .back)
        case "browser_forward":
            self.init(tab: try reader.tab(), action: .forward)
        case "browser_reload":
            self.init(tab: try reader.tab(), action: .reload)
        case "browser_snapshot":
            self.init(tab: try reader.tab(), action: .snapshot)
        case "browser_click":
            self.init(tab: try reader.tab(), action: .click(ref: try reader.requiredString("ref")))
        case "browser_type":
            self.init(tab: try reader.tab(), action: .type(
                ref: try reader.requiredString("ref"), text: try reader.requiredString("text", allowEmpty: true),
                submit: try reader.bool("submit") ?? false
            ))
        case "browser_press":
            let key = try reader.requiredString("key")
            guard let combo = LeoBrowserKeyCombo(key) else { throw LeoBrowserError.invalidArgs("Unrecognised key \(key.debugDescription)") }
            self.init(tab: try reader.tab(), action: .press(combo))
        case "browser_screenshot":
            self.init(tab: try reader.tab(), action: .screenshot(fullPage: try reader.bool("full_page") ?? false))
        case "browser_wait":
            self.init(tab: try reader.tab(), action: .wait(try Self.waitCondition(reader)))
        case "browser_eval":
            self.init(tab: try reader.tab(), action: .eval(js: try reader.requiredString("js")))
        case "browser_console":
            self.init(tab: try reader.tab(), action: .console(since: try reader.int("since")))
        case "browser_tabs":
            self.init(tab: nil, action: .tabs)
        case "browser_tab_new":
            self.init(tab: nil, action: .tabNew(url: try reader.string("url")))
        case "browser_tab_select":
            self.init(tab: nil, action: .tabSelect(tab: try reader.requiredTab()))
        case "browser_tab_close":
            self.init(tab: nil, action: .tabClose(tab: try reader.requiredTab()))
        case "browser_handoff":
            self.init(tab: nil, action: .handoff(message: try reader.requiredString("message")))
        default:
            throw LeoBrowserError.invalidArgs("Unknown browser tool \(tool.debugDescription)")
        }
    }

    /// The longest `browser_wait` the page honours, in milliseconds.
    public static let maximumWaitMilliseconds = 25_000

    private static func waitCondition(_ reader: LeoBrowserArgs) throws -> LeoBrowserAction.WaitCondition {
        let text = try reader.string("text")
        let milliseconds = try reader.int("ms")
        switch (text, milliseconds) {
        case (let text?, nil):
            guard !text.isEmpty else { throw LeoBrowserError.invalidArgs("text must not be empty") }
            return .text(text)
        case (nil, let milliseconds?):
            guard (0...maximumWaitMilliseconds).contains(milliseconds) else {
                throw LeoBrowserError.invalidArgs("ms must be between 0 and \(maximumWaitMilliseconds)")
            }
            return .milliseconds(milliseconds)
        default:
            throw LeoBrowserError.invalidArgs("Pass exactly one of text or ms")
        }
    }
}

public enum LeoBrowserAction: Equatable, Sendable {
    public enum WaitCondition: Equatable, Sendable {
        case text(String)
        case milliseconds(Int)
    }

    case navigate(url: String)
    case back
    case forward
    case reload
    case snapshot
    case click(ref: String)
    case type(ref: String, text: String, submit: Bool)
    case press(LeoBrowserKeyCombo)
    case screenshot(fullPage: Bool)
    case wait(WaitCondition)
    case eval(js: String)
    /// `since` is a message cursor from an earlier call; nil means everything
    /// captured since the last call.
    case console(since: Int?)
    case tabs
    case tabNew(url: String?)
    case tabSelect(tab: Int)
    case tabClose(tab: Int)
    case handoff(message: String)

    /// Whether the action changes the page or the tab set, and so fails with
    /// `user_has_control` while the user has the browser. Reads still work.
    public var changesPage: Bool {
        switch self {
        case .navigate, .back, .forward, .reload, .click, .type, .press, .eval, .tabNew, .tabSelect, .tabClose: true
        case .snapshot, .screenshot, .wait, .console, .tabs, .handoff: false
        }
    }
}

/// Typed reads of a tool's JSON args; every failure is `invalid_args`.
private struct LeoBrowserArgs {
    private let values: [String: LeoJSONValue]

    init(_ args: LeoJSONValue) throws {
        switch args {
        case .object(let values): self.values = values
        case .null: values = [:]
        default: throw LeoBrowserError.invalidArgs("Arguments must be a JSON object")
        }
    }

    func string(_ key: String) throws -> String? {
        guard let value = values[key], value != .null else { return nil }
        guard let string = value.stringValue else { throw LeoBrowserError.invalidArgs("\(key) must be a string") }
        return string
    }

    func requiredString(_ key: String, allowEmpty: Bool = false) throws -> String {
        guard let string = try string(key), allowEmpty || !string.isEmpty else {
            throw LeoBrowserError.invalidArgs("\(key) is required")
        }
        return string
    }

    func int(_ key: String) throws -> Int? {
        guard let value = values[key], value != .null else { return nil }
        guard let int = value.intValue else { throw LeoBrowserError.invalidArgs("\(key) must be an integer") }
        return int
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key], value != .null else { return nil }
        guard let bool = value.boolValue else { throw LeoBrowserError.invalidArgs("\(key) must be a boolean") }
        return bool
    }

    func tab() throws -> Int? { try int("tab") }

    func requiredTab() throws -> Int {
        guard let tab = try int("tab") else { throw LeoBrowserError.invalidArgs("tab is required") }
        return tab
    }
}
