import Foundation
import Testing

@testable import LeoKit

struct LeoPluginNodeDecodingTests {
    private func decode(_ json: String) throws -> LeoPluginSlotRoot {
        try JSONDecoder().decode(LeoPluginSlotRoot.self, from: Data(json.utf8))
    }

    @Test func decodesListWithItemsAccessoriesAndActions() throws {
        let root = try decode("""
        {"type":"List","sections":[{"id":"s1","title":"Open","items":[
          {"id":"a","title":"PR 1","subtitle":"leo","sfSymbol":"circle",
           "accessories":[{"type":"Accessory","text":"ok","color":"success"}],
           "actions":[{"type":"callback","id":"open"}]}]}]}
        """)
        guard case .list(let list) = root.nodes[0] else { Issue.record("not list"); return }
        #expect(list.sections[0].items[0].id == "a")
        #expect(list.sections[0].items[0].accessories[0].color == .success)
        #expect(list.sections[0].items[0].actions.count == 1)
    }

    @Test func rootAcceptsSingleNodeOrArray() throws {
        let one = try decode(#"{"type":"Loading"}"#)
        let many = try decode(#"[{"type":"Loading"},{"type":"EmptyState","title":"None"}]"#)
        #expect(one.nodes.count == 1)
        #expect(many.nodes.count == 2)
    }

    @Test func decodesEachOtherComponent() throws {
        let root = try decode("""
        [{"type":"Detail","markdown":"# Hi"},
         {"type":"Form","id":"f","fields":[
           {"id":"t","type":"text","label":"T"},{"id":"ta","type":"textArea"},
           {"id":"p","type":"picker","options":[{"value":"a","title":"A"}]},
           {"id":"c","type":"checkbox","checked":true},
           {"id":"go","type":"submit","label":"Go","action":{"type":"callback","id":"go"}}]},
         {"type":"Accessory","sfSymbol":"star","text":"3","color":"neutral","help":"stars"},
         {"type":"EmptyState","title":"x","message":"m"},
         {"type":"Loading"},
         {"type":"Error","message":"boom","retry":{"type":"callback","id":"retry"}}]
        """)
        #expect(root.nodes.count == 6)
    }

    @Test func rejectsUnknownType() {
        #expect(throws: DecodingError.self) { try decode(#"{"type":"WebView"}"#) }
    }

    @Test func rejectsLongAccessoryText() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"type":"Accessory","text":"123456789","color":"neutral"}"#)
        }
    }

    @Test func rejectsUnknownColorAndLongHelp() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"type":"Accessory","text":"a","color":"pink"}"#)
        }
        let help = String(repeating: "h", count: 81)
        #expect(throws: DecodingError.self) {
            try decode(#"{"type":"Accessory","text":"a","color":"neutral","help":"\#(help)"}"#)
        }
    }

    @Test func rejectsEmptyAndDuplicateItemIds() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"type":"List","sections":[{"items":[{"id":"","title":"x"}]}]}"#)
        }
        #expect(throws: DecodingError.self) {
            try decode(#"{"type":"List","sections":[{"items":[{"id":"a","title":"x"},{"id":"a","title":"y"}]}]}"#)
        }
    }

    @Test func rejectsMoreThanNodeLimit() {
        let items = (0..<2001).map { #"{"id":"i\#($0)","title":"t"}"# }.joined(separator: ",")
        #expect(throws: DecodingError.self) {
            try decode(#"{"type":"List","sections":[{"items":[\#(items)]}]}"#)
        }
    }

    @Test func rejectsPickerWithoutOptions() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"type":"Form","id":"f","fields":[{"id":"p","type":"picker"}]}"#)
        }
    }

    @Test func roundTrips() throws {
        let root = try decode(#"[{"type":"Loading"},{"type":"Detail","markdown":"x"}]"#)
        let data = try JSONEncoder().encode(root)
        #expect(try JSONDecoder().decode(LeoPluginSlotRoot.self, from: data) == root)
    }
}

struct LeoPluginDecodeBudgetTests {
    private func items(_ n: Int, prefix: String = "i") -> String {
        (0..<n).map { #"{"id":"\#(prefix)\#($0)","title":"t"}"# }.joined(separator: ",")
    }

    private func listJSON(items n: Int, prefix: String = "i", actions: String = "") -> String {
        #"{"type":"List","sections":[{"items":[\#(items(n, prefix: prefix))]}]\#(actions)}"#
    }

    private func decodeAction(_ json: String) throws -> LeoPluginAction {
        try JSONDecoder().decode(LeoPluginAction.self, from: Data(json.utf8))
    }

    @Test func pushViewCarrying2001ItemsIsRejectedWhileDecoding() {
        let json = #"{"type":"pushView","node":\#(listJSON(items: 2_001))}"#
        #expect(throws: DecodingError.self) { try decodeAction(json) }
    }

    @Test func pushViewWithinLimitDecodes() throws {
        let json = #"{"type":"pushView","node":\#(listJSON(items: 1_990))}"#
        _ = try decodeAction(json)
    }

    @Test func frameWith70000SectionsIsRejected() {
        let sections = [String](repeating: #"{"title":"x"}"#, count: 70_000).joined(separator: ",")
        let json = #"{"type":"List","sections":[\#(sections)]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LeoPluginSlotRoot.self, from: Data(json.utf8))
        }
    }

    @Test func frameWith38000ActionsIsRejected() {
        let actions = [String](repeating: #"{"type":"copy","text":"x"}"#, count: 38_000).joined(separator: ",")
        let json = #"{"type":"EmptyState","title":"t","actions":[\#(actions)]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LeoPluginSlotRoot.self, from: Data(json.utf8))
        }
    }

    @Test func itemAndFormActionsCountTowardTheBudget() {
        let actions = [String](repeating: #"{"type":"copy","text":"x"}"#, count: 2_001).joined(separator: ",")
        let item = #"{"type":"List","sections":[{"items":[{"id":"a","title":"t","actions":[\#(actions)]}]}]}"#
        let form = #"{"type":"Form","id":"f","fields":[{"id":"s","type":"submit","action":\#(#"{"type":"copy","text":"x"}"#)}]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LeoPluginSlotRoot.self, from: Data(item.utf8)) }
        #expect(throws: Never.self) { try JSONDecoder().decode(LeoPluginSlotRoot.self, from: Data(form.utf8)) }
    }

    @Test func pickerWith2001OptionsIsRejected() {
        let options = (0..<2_001).map { #"{"value":"v\#($0)","title":"t"}"# }.joined(separator: ",")
        let json = #"{"type":"Form","id":"f","fields":[{"id":"p","type":"picker","options":[\#(options)]}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LeoPluginSlotRoot.self, from: Data(json.utf8))
        }
    }

    @Test func budgetIsSharedAcrossRootAndNestedPushView() {
        let action = #"{"type":"pushView","node":\#(listJSON(items: 1_000, prefix: "n"))}"#
        let root = listJSON(items: 1_000, actions: "").replacingOccurrences(
            of: #""id":"i0","title":"t""#, with: #""id":"i0","title":"t","actions":[\#(action)]"#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LeoPluginSlotRoot.self, from: Data(root.utf8))
        }
    }

    @Test func budgetIsSharedWithCallbackResultTree() {
        let node = listJSON(items: 2_001)
        let json = #"{"call":"callbackResult","ref":"r","action":{"type":"pushView","node":\#(node)}}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LeoPluginHostRequest.self, from: Data(json.utf8))
        }
    }

    @Test func nestedPushViewChainBeyondDepthLimitIsRejected() {
        var json = #"{"type":"Loading"}"#
        for _ in 0..<10 {
            json = #"{"type":"List","sections":[{"items":[{"id":"a","title":"t","actions":[{"type":"pushView","node":\#(json)}]}]}]}"#
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LeoPluginSlotRoot.self, from: Data(json.utf8))
        }
    }

    @Test func budgetResetsBetweenDecodes() throws {
        let json = listJSON(items: 1_500)
        _ = try JSONDecoder().decode(LeoPluginSlotRoot.self, from: Data(json.utf8))
        _ = try JSONDecoder().decode(LeoPluginSlotRoot.self, from: Data(json.utf8))
    }

    @Test func oversizedFrameIsRejectedBeforeDecoding() {
        let padding = String(repeating: "a", count: LeoPluginFrameLimits.maxFrameBytes)
        let json = #"{"call":"log","level":"info","message":"\#(padding)"}"#
        #expect(throws: LeoPluginFrameError.self) { try LeoPluginFrame.decodeRequest(json) }
    }

    @Test func frameWithinCapDecodes() throws {
        let request = try LeoPluginFrame.decodeRequest(#"{"call":"log","level":"info","message":"hi"}"#)
        #expect(request == .log(level: "info", message: "hi"))
    }
}
