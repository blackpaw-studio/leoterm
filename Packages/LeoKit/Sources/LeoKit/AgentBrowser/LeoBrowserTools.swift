import Foundation

/// The agent browser's tool declarations: registered with each daemon as the
/// `browser` group. The daemon never sees the word "browser" in its own code;
/// these are the only schemas.
public enum LeoBrowserTools {
    public static let group = "browser"

    /// The daemon-side timeout of every tool but `browser_handoff`, which waits
    /// on the user (0 = no timeout).
    public static let defaultTimeoutSeconds = 30

    public static let definitions: [LeoClientToolDefinition] = [
        tool("browser_navigate", "Load a URL in the browser and wait for the page to finish loading. Only http, https and about:blank are allowed.",
             ["url": string("The URL to load, including http:// or https://.")], required: ["url"]),
        tool("browser_back", "Go back one entry in the tab's history.", [:]),
        tool("browser_forward", "Go forward one entry in the tab's history.", [:]),
        tool("browser_reload", "Reload the tab.", [:]),
        tool("browser_snapshot", "Read the page as a text tree of roles, names and values with a ref (e.g. e12) on each visible interactive element. Refs stay valid until the next snapshot or navigation in that tab.", [:]),
        tool("browser_click", "Click an element by ref from the latest snapshot.",
             ["ref": string("Element ref from browser_snapshot.")], required: ["ref"]),
        tool("browser_type", "Type text into an element by ref from the latest snapshot.",
             ["ref": string("Element ref from browser_snapshot."), "text": string("Text to type."),
              "submit": boolean("Press Enter after typing.")], required: ["ref", "text"]),
        tool("browser_press", "Press a key or chord, such as Enter, Escape, Tab, ArrowDown or Meta+a.",
             ["key": string("A key, optionally prefixed by modifiers joined with +: Shift, Control, Alt, Meta.")], required: ["key"]),
        tool("browser_screenshot", "Take a PNG screenshot of the tab, at most 1600 px wide.",
             ["full_page": boolean("Capture the whole scrollable page instead of the viewport.")]),
        tool("browser_wait", "Wait until text appears on the page, or for a fixed time. Pass exactly one of text or ms.",
             ["text": string("Wait until this text appears."), "ms": integer("Wait this many milliseconds, at most 25000.")]),
        tool("browser_eval", "Evaluate JavaScript in the page and return the JSON-serialised result.",
             ["js": string("JavaScript expression or statements to evaluate.")], required: ["js"]),
        tool("browser_console", "Return console messages (log, warn, error, unhandled rejections) captured in the tab since the last call.",
             ["since": integer("Message cursor from an earlier call; omit to continue from the last call.")]),
        tool("browser_tabs", "List the browser's tabs as {id, url, title, active}.", [:], pageTool: false),
        tool("browser_tab_new", "Open a new tab, optionally at a URL; it becomes the active tab. A browser holds at most 10 tabs.",
             ["url": string("URL to load in the new tab.")], pageTool: false),
        tool("browser_tab_select", "Make a tab the active tab.", ["tab": integer("Tab id from browser_tabs.")], required: ["tab"], pageTool: false),
        tool("browser_tab_close", "Close a tab.", ["tab": integer("Tab id from browser_tabs.")], required: ["tab"], pageTool: false),
        tool("browser_handoff", "Ask the user to take over the browser (to log in, solve a captcha). Blocks until they press Done or Decline; returns done or declined.",
             ["message": string("What you need the user to do.")], required: ["message"], timeoutSeconds: 0, pageTool: false),
    ]

    private static let tabProperty = integer("Tab id from browser_tabs; defaults to the active tab.")

    private static func tool(
        _ name: String, _ description: String, _ properties: [String: LeoJSONValue], required: [String] = [],
        timeoutSeconds: Int = defaultTimeoutSeconds, pageTool: Bool = true
    ) -> LeoClientToolDefinition {
        var properties = properties
        if pageTool { properties["tab"] = tabProperty }
        var schema: [String: LeoJSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map(LeoJSONValue.string)) }
        return LeoClientToolDefinition(name: name, description: description, inputSchema: .object(schema), timeoutSeconds: timeoutSeconds)
    }

    private static func string(_ description: String) -> LeoJSONValue { property("string", description) }
    private static func integer(_ description: String) -> LeoJSONValue { property("integer", description) }
    private static func boolean(_ description: String) -> LeoJSONValue { property("boolean", description) }

    private static func property(_ type: String, _ description: String) -> LeoJSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }
}
