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

    @Test func actionsCarryAnOptionalTitleAndSymbolAndKeepThemThroughARoundTrip() throws {
        let root = try decode("""
        {"type":"List","sections":[{"items":[{"id":"a","title":"PR","actions":[
          {"type":"callback","id":"merge","title":"Merge","sfSymbol":"arrow.merge"},
          {"type":"spawnAgent","repo":"a/b","branch":"x","prompt":"p","title":"Fix it"},
          {"type":"copy","text":"x"}]}]}]}
        """)
        guard case .list(let list) = root.nodes[0] else { Issue.record("not list"); return }
        let actions = list.sections[0].items[0].actions
        #expect(actions.map(\.title) == ["Merge", "Fix it", nil])
        #expect(actions.map(\.sfSymbol) == ["arrow.merge", nil, nil])
        #expect(actions[0].action == .callback(id: "merge", payload: .null))
        let again = try JSONDecoder().decode([LeoPluginLabeledAction].self, from: JSONEncoder().encode(actions))
        #expect(again == actions)
    }

    @Test func anActionTitleOverFortyCharactersIsRejectedAtDecode() {
        let long = String(repeating: "a", count: LeoPluginNodeLimits.maxActionTitle + 1)
        #expect(throws: DecodingError.self) {
            try decode(#"{"type":"EmptyState","title":"x","actions":[{"type":"copy","text":"x","title":"\#(long)"}]}"#)
        }
        let atLimit = String(repeating: "a", count: LeoPluginNodeLimits.maxActionTitle)
        #expect(throws: Never.self) {
            try decode(#"{"type":"EmptyState","title":"x","actions":[{"type":"copy","text":"x","title":"\#(atLimit)"}]}"#)
        }
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

    @Test func anAccessorySymbolOutsideTheAllowlistIsDroppedAtDecodeAndTheTextKept() throws {
        let root = try decode(#"{"type":"List","sections":[{"id":"s","title":"S","items":[{"id":"a","title":"t","accessories":[{"type":"Accessory","sfSymbol":"apple.logo","text":"3"},{"type":"Accessory","sfSymbol":"star","text":"4"}]}]}]}"#)

        guard case .list(let list) = root.nodes[0] else { Issue.record("not a list"); return }
        let accessories = list.sections[0].items[0].accessories
        #expect(accessories.map(\.sfSymbol) == [nil, "star"])
        #expect(accessories.map(\.text) == ["3", "4"])
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


// MARK: - Text and Meter

extension LeoPluginNodeDecodingTests {
    private func decodeRoot(_ json: String) throws -> LeoPluginSlotRoot {
        try JSONDecoder().decode(LeoPluginSlotRoot.self, from: Data(json.utf8))
    }

    private func textJSON(runs: Int, textLength: Int = 1) -> String {
        let run = #"{"text":"\#(String(repeating: "a", count: textLength))"}"#
        return #"{"type":"Text","runs":[\#(Array(repeating: run, count: runs).joined(separator: ","))]}"#
    }

    private func meterJSON(segments: Int = 1, value: String = "5", max: String = "10", extra: String = "") -> String {
        let segment = #"{"value":\#(value),"tone":"accent1"}"#
        return #"{"type":"Meter","segments":[\#(Array(repeating: segment, count: segments).joined(separator: ","))],"max":\#(max)\#(extra)}"#
    }

    @Test func textDecodesRunsWithToneWeightAndMono() throws {
        let root = try decodeRoot(#"{"type":"Text","runs":[{"text":"Opus","tone":"accent1","weight":"semibold","mono":true},{"text":" 62%"}]}"#)
        guard case .text(let text) = root.nodes[0] else { Issue.record("not text"); return }
        #expect(text.runs == [
            .init(text: "Opus", tone: .accent1, weight: .semibold, mono: true),
            .init(text: " 62%", tone: nil, weight: .regular, mono: false),
        ])
    }

    @Test func textRoundTrips() throws {
        let root = try decodeRoot(#"[{"type":"Text","runs":[{"text":"a","tone":"failure"}]},{"type":"Meter","segments":[{"value":1,"tone":"success"}],"max":4,"label":"25%","help":"1 of 4"}]"#)
        let again = try JSONDecoder().decode(LeoPluginSlotRoot.self, from: JSONEncoder().encode(root))
        #expect(again == root)
    }

    @Test func textLimitsAre20RunsAnd200CharactersPerRun() throws {
        _ = try decodeRoot(textJSON(runs: 20, textLength: 200))
        #expect(throws: DecodingError.self) { try decodeRoot(textJSON(runs: 21)) }
        #expect(throws: DecodingError.self) { try decodeRoot(textJSON(runs: 1, textLength: 201)) }
        #expect(throws: DecodingError.self) { try decodeRoot(textJSON(runs: 0)) }
    }

    @Test(arguments: [##""tone":"rainbow""##, ##""tone":"#ff0000""##, ##""tone":"Accent1""##, ##""weight":"bold""##])
    func textRejectsAnUnknownToneOrWeightIncludingRawHex(_ field: String) {
        #expect(throws: DecodingError.self) { try decodeRoot(#"{"type":"Text","runs":[{"text":"x",\#(field)}]}"#) }
    }

    @Test(arguments: ["secondary", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "success", "warning", "failure"])
    func everyDocumentedToneDecodes(_ tone: String) throws {
        _ = try decodeRoot(#"{"type":"Text","runs":[{"text":"x","tone":"\#(tone)"}]}"#)
        #expect(LeoPluginTone(rawValue: tone) != nil)
    }

    @Test func meterDecodesAndHonoursItsLimits() throws {
        let root = try decodeRoot(meterJSON(segments: 8, extra: #","label":"\#(String(repeating: "l", count: 40))","help":"\#(String(repeating: "h", count: 80))""#))
        guard case .meter(let meter) = root.nodes[0] else { Issue.record("not meter"); return }
        #expect(meter.segments.count == 8)
        #expect(meter.max == 10)
        #expect(throws: DecodingError.self) { try decodeRoot(meterJSON(segments: 9)) }
        #expect(throws: DecodingError.self) { try decodeRoot(meterJSON(segments: 0)) }
        #expect(throws: DecodingError.self) { try decodeRoot(meterJSON(extra: #","help":"\#(String(repeating: "h", count: 81))""#)) }
        #expect(throws: DecodingError.self) { try decodeRoot(meterJSON(extra: #","label":"\#(String(repeating: "l", count: 41))""#)) }
    }

    @Test(arguments: ["0", "-1", "1e999"])
    func meterRejectsANonPositiveOrNonFiniteMax(_ max: String) {
        #expect(throws: DecodingError.self) { try decodeRoot(meterJSON(max: max)) }
    }

    @Test(arguments: ["-0.5", "1e999"])
    func meterRejectsANegativeOrNonFiniteSegmentValue(_ value: String) {
        #expect(throws: DecodingError.self) { try decodeRoot(meterJSON(value: value)) }
    }

    @Test func meterAllowsSegmentsThatSumPastMaxAndZeroValues() throws {
        _ = try decodeRoot(meterJSON(segments: 3, value: "9"))
        _ = try decodeRoot(meterJSON(value: "0"))
    }

    @Test func meterRejectsAnUnknownSegmentTone() {
        #expect(throws: DecodingError.self) {
            try decodeRoot(##"{"type":"Meter","segments":[{"value":1,"tone":"#fff"}],"max":2}"##)
        }
    }

    @Test func eachTextAndMeterCountsAsOneNodeTowardTheLimit() throws {
        let nodes = Array(repeating: #"{"type":"Text","runs":[{"text":"x"}]}"#, count: LeoPluginNodeLimits.maxNodes).joined(separator: ",")
        let root = try decodeRoot("[\(nodes)]")
        #expect(root.nodes.count == LeoPluginNodeLimits.maxNodes)
        let over = Array(repeating: #"{"type":"Meter","segments":[{"value":1,"tone":"success"}],"max":2}"#, count: LeoPluginNodeLimits.maxNodes + 1)
            .joined(separator: ",")
        #expect(throws: DecodingError.self) { try decodeRoot("[\(over)]") }
    }

    @Test func theUnknownTypeMessageNamesTextAndMeter() {
        do {
            _ = try decodeRoot(#"{"type":"Gauge"}"#)
            Issue.record("expected a failure")
        } catch {
            #expect("\(error)".contains("Text"))
            #expect("\(error)".contains("Meter"))
        }
    }
}
