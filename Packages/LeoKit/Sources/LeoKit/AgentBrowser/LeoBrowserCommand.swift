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
        case "browser_hover":
            self.init(tab: try reader.tab(), action: .hover(ref: try reader.requiredString("ref")))
        case "browser_select_option":
            self.init(tab: try reader.tab(), action: .selectOption(ref: try reader.requiredString("ref"), values: try Self.selectValues(reader)))
        case "browser_drag":
            self.init(tab: try reader.tab(), action: .drag(startRef: try reader.requiredString("start_ref"), endRef: try reader.requiredString("end_ref")))
        case "browser_type":
            self.init(tab: try reader.tab(), action: .type(
                ref: try reader.requiredString("ref"), text: try reader.requiredString("text", allowEmpty: true),
                submit: try reader.bool("submit") ?? false
            ))
        case "browser_upload":
            self.init(tab: try reader.tab(), action: .upload(ref: try reader.requiredString("ref"), paths: try Self.uploadPaths(reader)))
        case "browser_press":
            let key = try reader.requiredString("key")
            guard let combo = LeoBrowserKeyCombo(key) else { throw LeoBrowserError.invalidArgs("Unrecognised key \(key.debugDescription)") }
            self.init(tab: try reader.tab(), action: .press(combo))
        case "browser_screenshot":
            self.init(tab: try reader.tab(), action: .screenshot(
                fullPage: try reader.bool("full_page") ?? false, path: try Self.capturePath(reader, kind: .png)
            ))
        case "browser_pdf":
            self.init(tab: try reader.tab(), action: .pdf(path: try Self.capturePath(reader, kind: .pdf)))
        case "browser_wait":
            self.init(tab: try reader.tab(), action: .wait(try Self.waitCondition(reader)))
        case "browser_eval":
            self.init(tab: try reader.tab(), action: .eval(js: try reader.requiredString("js")))
        case "browser_console":
            self.init(tab: try reader.tab(), action: .console(since: try reader.int("since")))
        case "browser_tabs":
            self.init(tab: nil, action: .tabs)
        case "browser_tab_new":
            self.init(tab: nil, action: .tabNew(url: try reader.string("url"), userAgent: try Self.userAgent(reader, required: false)))
        case "browser_tab_select":
            self.init(tab: nil, action: .tabSelect(tab: try reader.requiredTab()))
        case "browser_tab_close":
            self.init(tab: nil, action: .tabClose(tab: try reader.requiredTab()))
        case "browser_user_agent":
            self.init(tab: try reader.tab(), action: .setUserAgent(try Self.userAgent(reader, required: true)))
        case "browser_downloads":
            self.init(tab: nil, action: .downloads)
        case "browser_handoff":
            self.init(tab: nil, action: .handoff(message: try reader.requiredString("message")))
        case "browser_dialog":
            self.init(tab: try reader.tab(), action: try Self.dialog(reader))
        default:
            throw LeoBrowserError.invalidArgs("Unknown browser tool \(tool.debugDescription)")
        }
    }

    /// The longest `browser_wait` the page honours, in milliseconds.
    public static let maximumWaitMilliseconds = 25_000

    /// The most values one `browser_select_option` takes.
    public static let maximumSelectValues = 100

    /// The most files one `browser_upload` sets.
    public static let maximumUploadFiles = 20

    /// The longest user agent an override accepts, in characters.
    public static let maximumUserAgentLength = 1024

    /// The `user_agent` arg: nil for "no override" (an empty or whitespace-only
    /// string). When `required`, a missing or null value is `invalid_args`, so
    /// a bare call cannot wipe an override by accident; only `""` clears.
    /// The value goes out in a request header, so it must be printable ASCII
    /// (0x20-0x7E): no CR/LF, NUL or other control characters, and nothing
    /// non-ASCII.
    private static func userAgent(_ reader: LeoBrowserArgs, required: Bool) throws -> String? {
        guard let userAgent = try reader.string("user_agent") else {
            if required { throw LeoBrowserError.invalidArgs("user_agent is required; pass an empty string to clear the override") }
            return nil
        }
        guard !userAgent.allSatisfy(\.isWhitespace) else { return nil }
        guard userAgent.count <= maximumUserAgentLength else {
            throw LeoBrowserError.invalidArgs("user_agent must be at most \(maximumUserAgentLength) characters")
        }
        guard userAgent.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else {
            throw LeoBrowserError.invalidArgs("user_agent must be printable ASCII")
        }
        return userAgent
    }

    /// The optional `path` of a capture, its form checked here so a bad one
    /// fails before the page is captured; the workspace check comes at save.
    private static func capturePath(_ reader: LeoBrowserArgs, kind: LeoBrowserCaptureKind) throws -> String? {
        guard let path = try reader.string("path") else { return nil }
        try LeoBrowserCapturePath.validate(path, kind: kind)
        return path
    }

    /// `values`: 1 to `maximumSelectValues` strings; an empty one is a real
    /// option value, so blanks stay.
    private static func selectValues(_ reader: LeoBrowserArgs) throws -> [String] {
        guard let values = try reader.stringArray("values"), !values.isEmpty else {
            throw LeoBrowserError.invalidArgs("values is required: at least one option value or label")
        }
        guard values.count <= maximumSelectValues else { throw LeoBrowserError.invalidArgs("values takes at most \(maximumSelectValues) options") }
        return values
    }

    /// `paths`: 1 to `maximumUploadFiles` non-blank strings without NUL.
    /// Whether each is inside the workspace is the reader's call.
    private static func uploadPaths(_ reader: LeoBrowserArgs) throws -> [String] {
        guard let paths = try reader.stringArray("paths"), !paths.isEmpty else { throw LeoBrowserError.invalidArgs("paths is required: at least one workspace file") }
        guard paths.count <= maximumUploadFiles else { throw LeoBrowserError.invalidArgs("paths takes at most \(maximumUploadFiles) files") }
        guard paths.allSatisfy({ !$0.allSatisfy(\.isWhitespace) }) else { throw LeoBrowserError.invalidArgs("paths must not be blank") }
        guard !paths.contains(where: { $0.contains("\0") }) else { throw LeoBrowserError.invalidArgs("paths must not contain NUL") }
        return paths
    }

    /// `action` accept or dismiss; `text` only with accept. Whether the
    /// open dialog is a prompt that takes text is checked when the tool runs.
    private static func dialog(_ reader: LeoBrowserArgs) throws -> LeoBrowserAction {
        let accept: Bool
        switch try reader.requiredString("action") {
        case "accept": accept = true
        case "dismiss": accept = false
        case let other: throw LeoBrowserError.invalidArgs("action must be accept or dismiss, not \(other.debugDescription)")
        }
        let text = try reader.string("text")
        guard text == nil || accept else { throw LeoBrowserError.invalidArgs("text goes with accept, to answer a prompt; dismiss takes none") }
        return .dialog(accept: accept, text: text)
    }

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
    /// Moves the pointer over the element for `ref`, leaving it there.
    case hover(ref: String)
    /// Selects the options of the `<select>` for `ref` whose value or label
    /// is each of `values`.
    case selectOption(ref: String, values: [String])
    /// Presses on the element for `startRef`, moves to the element for
    /// `endRef` and releases.
    case drag(startRef: String, endRef: String)
    case type(ref: String, text: String, submit: Bool)
    /// Sets workspace files, as given, on the file input for `ref`.
    case upload(ref: String, paths: [String])
    case press(LeoBrowserKeyCombo)
    /// With a `path`, the PNG is saved into the workspace instead of returned.
    case screenshot(fullPage: Bool, path: String?)
    /// The whole page as one continuous PDF page, saved into the workspace.
    case pdf(path: String?)
    case wait(WaitCondition)
    case eval(js: String)
    /// `since` is a message cursor from an earlier call; nil means everything
    /// captured since the last call.
    case console(since: Int?)
    case tabs
    /// `userAgent` overrides the tab's user agent from its first load; nil keeps the default.
    case tabNew(url: String?, userAgent: String?)
    case tabSelect(tab: Int)
    case tabClose(tab: Int)
    /// Sets the tab's user agent override; nil clears it back to the default.
    case setUserAgent(String?)
    /// This app session's downloads, newest first.
    case downloads
    case handoff(message: String)
    /// Answers the tab's JavaScript dialog (B-412); `text` answers a prompt.
    case dialog(accept: Bool, text: String?)

    /// Whether the action needs the tab's page to run, so fails with
    /// `dialog_open` while a JavaScript dialog pauses it (B-412). A
    /// screenshot does: WebKit draws it in the page's own process.
    public var needsPage: Bool {
        switch self {
        case .navigate, .back, .forward, .reload, .snapshot, .click, .hover, .selectOption, .drag, .type, .upload, .press, .screenshot, .pdf, .wait(.text), .eval, .setUserAgent: true
        case .wait(.milliseconds), .console, .tabs, .tabNew, .tabSelect, .tabClose, .downloads, .handoff, .dialog: false
        }
    }

    /// Whether the action changes the page or the tab set, and so fails with
    /// `user_has_control` while the user has the browser. Reads still work.
    public var changesPage: Bool {
        switch self {
        case .navigate, .back, .forward, .reload, .click, .hover, .selectOption, .drag, .type, .upload, .press, .eval, .tabNew, .tabSelect, .tabClose, .setUserAgent, .dialog: true
        case .snapshot, .screenshot, .pdf, .wait, .console, .tabs, .downloads, .handoff: false
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

    func stringArray(_ key: String) throws -> [String]? {
        guard let value = values[key], value != .null else { return nil }
        let mistyped = LeoBrowserError.invalidArgs("\(key) must be an array of strings")
        guard case .array(let items) = value else { throw mistyped }
        let strings = items.compactMap(\.stringValue)
        guard strings.count == items.count else { throw mistyped }
        return strings
    }

    func tab() throws -> Int? { try int("tab") }

    func requiredTab() throws -> Int {
        guard let tab = try int("tab") else { throw LeoBrowserError.invalidArgs("tab is required") }
        return tab
    }
}
