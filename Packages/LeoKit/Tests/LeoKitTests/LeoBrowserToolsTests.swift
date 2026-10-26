import Foundation
import Testing

@testable import LeoKit

struct LeoBrowserToolsTests {
    @Test func declaresEveryToolInTheSpecTable() {
        #expect(LeoBrowserTools.definitions.map(\.name) == [
            "browser_navigate", "browser_back", "browser_forward", "browser_reload", "browser_snapshot", "browser_click",
            "browser_type", "browser_press", "browser_screenshot", "browser_wait", "browser_eval", "browser_console",
            "browser_tabs", "browser_tab_new", "browser_tab_select", "browser_tab_close", "browser_handoff",
        ])
    }

    @Test func handoffHasNoTimeoutAndEveryOtherToolThirtySeconds() {
        for tool in LeoBrowserTools.definitions {
            #expect(tool.timeoutSeconds == (tool.name == "browser_handoff" ? 0 : 30), "\(tool.name)")
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
        for name in ["browser_tabs", "browser_handoff", "browser_tab_new"] { #expect(properties(name)["tab"] == nil, "\(name)") }
        func required(_ name: String) -> [LeoJSONValue] {
            guard case .array(let list) = LeoBrowserTools.definitions.first(where: { $0.name == name })?.inputSchema.objectValue?["required"] else { return [] }
            return list
        }
        for name in ["browser_tab_select", "browser_tab_close"] { #expect(required(name) == [.string("tab")], "\(name)") }
    }

    @Test func everyDefinitionDecodesFromItsOwnSampleArgs() throws {
        for tool in LeoBrowserTools.definitions {
            _ = try LeoBrowserCommand(tool: tool.name, args: .object(LeoBrowserCommandTests.sampleArgs[tool.name] ?? [:]))
        }
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
            "invalid_args", "js_error", "navigation_failed", "no_such_tab", "scheme_not_allowed", "stale_ref",
            "tab_limit", "timeout", "user_has_control",
        ])
    }
}
