import Foundation
import Testing

@testable import LeoKit

struct LeoBrowserCommandTests {
    private func decode(_ tool: String, _ args: [String: LeoJSONValue] = [:]) throws -> LeoBrowserCommand {
        try LeoBrowserCommand(tool: tool, args: .object(args))
    }

    private func invalidArgs(_ tool: String, _ args: [String: LeoJSONValue] = [:], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: LeoBrowserError.self, sourceLocation: sourceLocation) { _ = try self.decode(tool, args) }
        do { _ = try decode(tool, args) } catch let error as LeoBrowserError {
            #expect(error.code == .invalidArgs, "\(tool): \(error)", sourceLocation: sourceLocation)
        } catch {}
    }

    @Test func everyToolDecodesToItsAction() throws {
        #expect(try decode("browser_navigate", ["url": .string("https://a.test")]).action == .navigate(url: "https://a.test"))
        #expect(try decode("browser_back").action == .back)
        #expect(try decode("browser_forward").action == .forward)
        #expect(try decode("browser_reload").action == .reload)
        #expect(try decode("browser_snapshot").action == .snapshot)
        #expect(try decode("browser_click", ["ref": .string("e3")]).action == .click(ref: "e3"))
        #expect(try decode("browser_type", ["ref": .string("e3"), "text": .string("hi")]).action == .type(ref: "e3", text: "hi", submit: false))
        #expect(try decode("browser_type", ["ref": .string("e3"), "text": .string("hi"), "submit": .bool(true)]).action == .type(ref: "e3", text: "hi", submit: true))
        #expect(try decode("browser_press", ["key": .string("Meta+a")]).action == .press(try #require(LeoBrowserKeyCombo("Meta+a"))))
        #expect(try decode("browser_screenshot").action == .screenshot(fullPage: false))
        #expect(try decode("browser_screenshot", ["full_page": .bool(true)]).action == .screenshot(fullPage: true))
        #expect(try decode("browser_wait", ["text": .string("Done")]).action == .wait(.text("Done")))
        #expect(try decode("browser_wait", ["ms": .int(250)]).action == .wait(.milliseconds(250)))
        #expect(try decode("browser_eval", ["js": .string("1+1")]).action == .eval(js: "1+1"))
        #expect(try decode("browser_console").action == .console(since: nil))
        #expect(try decode("browser_console", ["since": .int(12)]).action == .console(since: 12))
        #expect(try decode("browser_tabs").action == .tabs)
        #expect(try decode("browser_tab_new").action == .tabNew(url: nil))
        #expect(try decode("browser_tab_new", ["url": .string("https://a.test")]).action == .tabNew(url: "https://a.test"))
        #expect(try decode("browser_tab_select", ["tab": .int(2)]).action == .tabSelect(tab: 2))
        #expect(try decode("browser_tab_close", ["tab": .int(2)]).action == .tabClose(tab: 2))
        #expect(try decode("browser_handoff", ["message": .string("Log in")]).action == .handoff(message: "Log in"))
    }

    @Test func optionalTabTargetsAPageToolAndDefaultsToNil() throws {
        #expect(try decode("browser_click", ["ref": .string("e1")]).tab == nil)
        #expect(try decode("browser_click", ["ref": .string("e1"), "tab": .int(4)]).tab == 4)
        #expect(try decode("browser_snapshot", ["tab": .int(1)]).tab == 1)
    }

    @Test func tabLevelToolsTakeNoPageTab() throws {
        #expect(try decode("browser_tabs", ["tab": .int(3)]).tab == nil)
        #expect(try decode("browser_handoff", ["message": .string("x"), "tab": .int(3)]).tab == nil)
        #expect(try decode("browser_tab_select", ["tab": .int(3)]).tab == nil)
        #expect(try decode("browser_tab_new", ["tab": .int(3)]).tab == nil)
    }

    @Test func missingOrMistypedRequiredArgsAreInvalidArgs() {
        invalidArgs("browser_click")
        invalidArgs("browser_click", ["ref": .string("")])
        invalidArgs("browser_click", ["ref": .int(3)])
        invalidArgs("browser_navigate")
        invalidArgs("browser_type", ["ref": .string("e1")])
        invalidArgs("browser_type", ["text": .string("x")])
        invalidArgs("browser_press")
        invalidArgs("browser_press", ["key": .string("Hyper+q")])
        invalidArgs("browser_eval")
        invalidArgs("browser_tab_select")
        invalidArgs("browser_tab_close", ["tab": .string("2")])
        invalidArgs("browser_handoff")
        invalidArgs("browser_click", ["ref": .string("e1"), "tab": .string("x")])
        invalidArgs("browser_screenshot", ["full_page": .string("yes")])
    }

    @Test func waitNeedsExactlyOneConditionWithinLimits() {
        invalidArgs("browser_wait")
        invalidArgs("browser_wait", ["text": .string("a"), "ms": .int(10)])
        invalidArgs("browser_wait", ["ms": .int(25_001)])
        invalidArgs("browser_wait", ["ms": .int(-1)])
        invalidArgs("browser_wait", ["text": .string("")])
        #expect((try? decode("browser_wait", ["ms": .int(25_000)])) != nil)
        #expect((try? decode("browser_wait", ["ms": .int(0)])) != nil)
    }

    @Test func anUnknownToolIsInvalidArgs() {
        invalidArgs("browser_teleport")
    }

    @Test func nonObjectArgsAreInvalidArgs() {
        #expect(throws: LeoBrowserError.self) { _ = try LeoBrowserCommand(tool: "browser_back", args: .string("x")) }
    }

    @Test func nullArgsMeanNoArgs() throws {
        #expect(try LeoBrowserCommand(tool: "browser_back", args: .null).action == .back)
    }

    @Test func wholeNumberDoublesCountAsIntegers() throws {
        #expect(try decode("browser_wait", ["ms": .double(250)]).action == .wait(.milliseconds(250)))
        invalidArgs("browser_wait", ["ms": .double(250.5)])
    }

    @Test func mutatingFlagMarksTheActionsThatChangeThePage() throws {
        let mutating: Set<String> = [
            "browser_navigate", "browser_back", "browser_forward", "browser_reload", "browser_click", "browser_type",
            "browser_press", "browser_eval", "browser_tab_new", "browser_tab_select", "browser_tab_close",
        ]
        for tool in LeoBrowserTools.definitions.map(\.name) {
            let command = try decode(tool, LeoBrowserCommandTests.sampleArgs[tool] ?? [:])
            #expect(command.action.changesPage == mutating.contains(tool), "\(tool)")
        }
    }

    static let sampleArgs: [String: [String: LeoJSONValue]] = [
        "browser_navigate": ["url": .string("https://a.test")],
        "browser_click": ["ref": .string("e1")],
        "browser_type": ["ref": .string("e1"), "text": .string("x")],
        "browser_press": ["key": .string("Enter")],
        "browser_wait": ["ms": .int(1)],
        "browser_eval": ["js": .string("1")],
        "browser_tab_select": ["tab": .int(1)],
        "browser_tab_close": ["tab": .int(1)],
        "browser_handoff": ["message": .string("hi")],
    ]
}
