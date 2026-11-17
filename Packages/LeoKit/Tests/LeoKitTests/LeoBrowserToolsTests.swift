import Foundation
import Testing

@testable import LeoKit

struct LeoBrowserToolsTests {
    @Test func declaresEveryToolInTheSpecTable() {
        #expect(LeoBrowserTools.definitions.map(\.name) == [
            "browser_navigate", "browser_back", "browser_forward", "browser_reload", "browser_snapshot", "browser_click",
            "browser_hover", "browser_select_option", "browser_drag", "browser_type", "browser_upload", "browser_press", "browser_screenshot", "browser_pdf", "browser_wait", "browser_eval", "browser_console",
            "browser_tabs", "browser_tab_new", "browser_tab_select", "browser_tab_close", "browser_user_agent", "browser_downloads",
            "browser_handoff", "browser_dialog",
        ])
    }

    /// B-412: the agent learns what each action presses, that the page is
    /// paused meanwhile, and that the user may answer first.
    @Test func dialogSaysWhatItAnswersAndThatTheUserMayAnswerFirst() throws {
        let tool = try #require(LeoBrowserTools.definitions.first { $0.name == "browser_dialog" })
        for phrase in ["alert", "confirm", "prompt", "beforeunload", "paused", "dialog_open", "browser pane", "answer it first", "dialog_handled", "Leave Page"] {
            #expect(tool.description.contains(phrase), "\(phrase)")
        }
        let schema = try #require(tool.inputSchema.objectValue)
        #expect(schema["required"] == .array([.string("action")]))
        let properties = try #require(schema["properties"]?.objectValue)
        #expect(properties["action"]?.objectValue?["enum"] == .array([.string("accept"), .string("dismiss")]))
        #expect(properties["text"]?.objectValue?["type"] == .string("string"))
        #expect(properties["tab"] != nil)
        #expect(tool.timeoutSeconds == 30)
        let tabs = try #require(LeoBrowserTools.definitions.first { $0.name == "browser_tabs" })
        #expect(tabs.description.contains("dialog: {kind, message, default_text, site}"))
    }

    @Test func handoffHasNoTimeoutUploadTwoMinutesAndEveryOtherToolThirtySeconds() {
        let expected = ["browser_handoff": 0, "browser_upload": 120]
        for tool in LeoBrowserTools.definitions {
            #expect(tool.timeoutSeconds == expected[tool.name, default: 30], "\(tool.name)")
        }
    }

    @Test func pointerToolsAddressElementsByRefLikeClick() throws {
        func definition(_ name: String) throws -> LeoClientToolDefinition { try #require(LeoBrowserTools.definitions.first { $0.name == name }) }
        func schema(_ name: String) throws -> [String: LeoJSONValue] { try #require(try definition(name).inputSchema.objectValue) }
        func properties(_ name: String) throws -> [String: LeoJSONValue] { try #require(try schema(name)["properties"]?.objectValue) }

        let hover = try definition("browser_hover")
        #expect(try schema("browser_hover")["required"] == .array([.string("ref")]))
        #expect(try properties("browser_hover")["ref"] != nil)
        #expect(try properties("browser_hover")["tab"] != nil)
        #expect(hover.description.contains("by ref from the latest snapshot"))
        #expect(hover.description.hasPrefix("Leo app browser: "))

        let select = try definition("browser_select_option")
        #expect(try schema("browser_select_option")["required"] == .array([.string("ref"), .string("values")]))
        #expect(try properties("browser_select_option")["tab"] != nil)
        let values = try #require(try properties("browser_select_option")["values"]?.objectValue)
        #expect(values["type"] == .string("array"))
        #expect(values["items"] == .object(["type": .string("string")]))
        #expect(values["minItems"] == .int(1))
        #expect(values["maxItems"] == .int(LeoBrowserCommand.maximumSelectValues))
        #expect(select.description.hasPrefix("Leo app browser: "))

        let drag = try definition("browser_drag")
        #expect(try schema("browser_drag")["required"] == .array([.string("start_ref"), .string("end_ref")]))
        #expect(try properties("browser_drag")["tab"] != nil)
        #expect(drag.description.hasPrefix("Leo app browser: "))
        for phrase in ["by refs from the latest snapshot", "draggable", "dragstart", "drop", "mouse events"] {
            #expect(drag.description.contains(phrase), "\(phrase)")
        }
        for phrase in ["by ref from the latest snapshot", "<select>", "value", "label", "[multiple]", "browser_click"] {
            #expect(select.description.contains(phrase), "\(phrase)")
        }
    }

    @Test func uploadTakesARefAndAListOfWorkspacePaths() throws {
        let tool = try #require(LeoBrowserTools.definitions.first { $0.name == "browser_upload" })
        let schema = try #require(tool.inputSchema.objectValue)
        #expect(schema["required"] == .array([.string("ref"), .string("paths")]))
        let paths = try #require(schema["properties"]?.objectValue?["paths"]?.objectValue)
        #expect(paths["type"] == .string("array"))
        #expect(paths["items"] == .object(["type": .string("string")]))
        #expect(paths["minItems"] == .int(1))
        #expect(paths["maxItems"] == .int(20))
        #expect(schema["properties"]?.objectValue?["tab"] != nil)
        for phrase in ["workspace", "[file]", "multiple", "25 MB", "browser_click"] {
            #expect(tool.description.contains(phrase), "\(phrase)")
        }
    }

    @Test func theGroupAndNamesSatisfyTheDaemonRules() throws {
        #expect(LeoBrowserTools.group == "browser")
        let pattern = try Regex("^[a-z][a-z0-9_]{0,63}$")
        for tool in LeoBrowserTools.definitions {
            #expect(tool.name.wholeMatch(of: pattern) != nil, "\(tool.name)")
            #expect(tool.inputSchema.objectValue?["type"] == .string("object"), "\(tool.name)")
            #expect(!tool.description.isEmpty, "\(tool.name)")
        }
        #expect(LeoBrowserTools.definitions.count <= 64)
    }

    @Test func tabsHandoffSelectAndCloseDeclareNoOptionalTabProperty() {
        func properties(_ name: String) -> [String: LeoJSONValue] {
            LeoBrowserTools.definitions.first { $0.name == name }?.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        }
        #expect(properties("browser_click")["tab"] != nil)
        for name in ["browser_tabs", "browser_handoff", "browser_tab_new", "browser_downloads"] { #expect(properties(name)["tab"] == nil, "\(name)") }
        func required(_ name: String) -> [LeoJSONValue] {
            guard case .array(let list) = LeoBrowserTools.definitions.first(where: { $0.name == name })?.inputSchema.objectValue?["required"] else { return [] }
            return list
        }
        for name in ["browser_tab_select", "browser_tab_close"] { #expect(required(name) == [.string("tab")], "\(name)") }
    }

    @Test func userAgentParametersSayWhatTheyDo() throws {
        func definition(_ name: String) throws -> LeoClientToolDefinition { try #require(LeoBrowserTools.definitions.first { $0.name == name }) }
        func property(_ name: String) throws -> String? {
            try definition(name).inputSchema.objectValue?["properties"]?.objectValue?["user_agent"]?.objectValue?["description"]?.stringValue
        }
        for name in ["browser_tab_new", "browser_user_agent"] {
            let text = try #require(try property(name), "\(name)")
            #expect(text.contains("navigator.userAgent"), "\(name)")
            #expect(text.contains("tab is closed"), "\(name)")
        }
        #expect(try property("browser_user_agent")?.contains("Pass an empty string to clear") == true)
        #expect(try definition("browser_user_agent").inputSchema.objectValue?["required"] == .array([.string("user_agent")]))
        let tool = try definition("browser_user_agent")
        #expect(tool.description.contains("next navigation"))
        #expect(tool.description.contains("default"))
    }

    @Test func everyDefinitionDecodesFromItsOwnSampleArgs() throws {
        for tool in LeoBrowserTools.definitions {
            _ = try LeoBrowserCommand(tool: tool.name, args: .object(LeoBrowserCommandTests.sampleArgs[tool.name] ?? [:]))
        }
    }

    @Test func everyDescriptionNamesTheLeoAppBrowserSoItIsNotMistakenForPlaywright() {
        for tool in LeoBrowserTools.definitions {
            #expect(tool.description.hasPrefix("Leo app browser: "), "\(tool.name)")
        }
    }

    @Test func entryPointsExplainWhoSeesTheBrowserWhereItsCookiesLiveAndHowLocalhostWorks() {
        for name in ["browser_navigate", "browser_tab_new"] {
            let description = LeoBrowserTools.definitions.first { $0.name == name }?.description ?? ""
            #expect(description.contains("browser pane in the user's Leo app"), "\(name)")
            #expect(description.contains("not a headless or Playwright browser"), "\(name)")
            #expect(description.contains("user can watch"), "\(name)")
            #expect(description.contains("cookies"), "\(name)")
            #expect(description.contains("localhost"), "\(name)")
        }
    }

    @Test func downloadsSaysWhereFilesLandAndThatNothingIsOverwritten() throws {
        let tool = try #require(LeoBrowserTools.definitions.first { $0.name == "browser_downloads" })
        #expect(tool.inputSchema.objectValue?["properties"] == .object([:]))
        for phrase in ["downloads/", "workspace", "never overwrites", "numbered", "workspace_path", "newest first"] {
            #expect(tool.description.contains(phrase), "\(phrase)")
        }
    }

    @Test func capturesSayWhereTheyLandAndThatNothingIsOverwritten() throws {
        func definition(_ name: String) throws -> LeoClientToolDefinition { try #require(LeoBrowserTools.definitions.first { $0.name == name }) }
        func path(_ name: String) throws -> String {
            try #require(try definition(name).inputSchema.objectValue?["properties"]?.objectValue?["path"]?.objectValue?["description"]?.stringValue)
        }
        let pdf = try definition("browser_pdf")
        for phrase in ["workspace", "never overwrites", "numbered", "workspace_path", "one continuous page"] {
            #expect(pdf.description.lowercased().contains(phrase), "\(phrase)")
        }
        #expect(pdf.inputSchema.objectValue?["required"] == nil)
        #expect(try path("browser_pdf").contains("downloads/"))
        #expect(try path("browser_pdf").contains("trailing /"))
        #expect(try definition("browser_screenshot").description.contains("path"))
        #expect(try path("browser_screenshot").contains("instead of returning the image"))
    }

    @Test func registrationMatchesTheGoldenFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/agent-browser/browser-tools.json")
        let golden = try Data(contentsOf: url)
        try LeoClientToolsWireTests.expectSameJSON(LeoBrowserTools.definitions, as: golden)
    }

    @Test func errorsMapToClientToolErrorsWithTheirCode() {
        let error = LeoBrowserError.userHasControl
        #expect(error.clientToolError == LeoClientToolError(code: "user_has_control", message: error.message))
        #expect(error.message.contains("browser_handoff"))
        #expect(LeoBrowserError.Code.allCases.map(\.rawValue).sorted() == [
            "dialog_handled", "dialog_open", "file_error", "invalid_args", "js_error", "localhost_unreachable", "navigation_failed", "no_dialog",
            "no_such_file", "no_such_tab", "save_failed", "scheme_not_allowed", "stale_ref", "tab_limit", "timeout", "unsupported", "user_has_control",
        ])
    }
}
