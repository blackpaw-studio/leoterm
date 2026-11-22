import Foundation
import Testing

@testable import LeoKit

/// apiVersion 2 nodes: the value-form `Meter` and `Group`.
private func decodeV2(_ json: String, apiVersion: Int = 2) throws -> LeoPluginSlotRoot {
    let decoder = JSONDecoder()
    decoder.userInfo[LeoPluginNodeDecoding.apiVersionKey] = apiVersion
    return try decoder.decode(LeoPluginSlotRoot.self, from: Data(json.utf8))
}

private let sessionMeter = #"{"type":"Meter","label":"Session","value":0.42,"valueText":"42%","detail":"resets in 2h 14m","tone":"success"}"#

private func groupJSON(children: String = sessionMeter) -> String {
    """
    {"type":"Group","title":"claude-blackpaw-leo","subtitle":"~/.claude-blackpaw-leo","sfSymbol":"clock",
     "accessory":{"text":"Stale","color":"warning"},"children":[\(children)],
     "actions":[{"type":"callback","id":"refresh","title":"Refresh"}]}
    """
}

extension LeoPluginNodeDecodingTests {
    @Test func aValueMeterDecodesEveryField() throws {
        let root = try decodeV2(sessionMeter)
        guard case .valueMeter(let meter) = root.nodes[0] else { Issue.record("not a value meter"); return }
        #expect(meter.label == "Session")
        #expect(meter.value == 0.42)
        #expect(meter.valueText == "42%")
        #expect(meter.detail == "resets in 2h 14m")
        #expect(meter.tone == .success)
    }

    @Test(arguments: [("1.7", 1.0), ("-0.3", 0.0), ("0", 0.0), ("1", 1.0)])
    func aValueMeterClampsItsValue(_ raw: String, _ expected: Double) throws {
        let root = try decodeV2(#"{"type":"Meter","label":"x","value":\#(raw),"tone":"neutral"}"#)
        guard case .valueMeter(let meter) = root.nodes[0] else { Issue.record("not a value meter"); return }
        #expect(meter.value == expected)
    }

    @Test func aNonFiniteValueIsRefused() {
        #expect(throws: DecodingError.self) { try decodeV2(#"{"type":"Meter","label":"x","value":1e999,"tone":"neutral"}"#) }
    }

    @Test func valuePlusSegmentsIsRefused() {
        let json = #"{"type":"Meter","label":"x","value":0.5,"tone":"neutral","segments":[{"value":1,"tone":"success"}],"max":2}"#
        #expect(throws: DecodingError.self) { try decodeV2(json) }
    }

    @Test func anUnknownValueMeterToneIsRefused() {
        #expect(throws: DecodingError.self) { try decodeV2(#"{"type":"Meter","label":"x","value":0.5,"tone":"accent1"}"#) }
    }

    @Test func aLongValueMeterLabelIsRefused() {
        let label = String(repeating: "a", count: LeoPluginNodeLimits.maxMeterLabel + 1)
        #expect(throws: DecodingError.self) { try decodeV2(#"{"type":"Meter","label":"\#(label)","value":0.5,"tone":"neutral"}"#) }
    }

    @Test func theSegmentsMeterIsUnchangedUnderBothVersions() throws {
        let json = #"{"type":"Meter","segments":[{"value":1,"tone":"success"}],"max":2,"label":"Ctx"}"#
        for version in [1, 2] {
            let root = try decodeV2(json, apiVersion: version)
            guard case .meter(let meter) = root.nodes[0] else { Issue.record("not a segments meter"); return }
            #expect(meter.max == 2)
        }
    }

    @Test func aGroupDecodesItsHeaderChildrenAndActions() throws {
        let root = try decodeV2(groupJSON(children: sessionMeter + #",{"type":"Accessory","text":"Pro"}"#))
        guard case .group(let group) = root.nodes[0] else { Issue.record("not a group"); return }
        #expect(group.title == "claude-blackpaw-leo")
        #expect(group.subtitle == "~/.claude-blackpaw-leo")
        #expect(group.sfSymbol == "clock")
        #expect(group.accessory?.text == "Stale")
        #expect(group.children.count == 2)
        guard case .meter(let meter) = group.children[0] else { Issue.record("first child not a meter"); return }
        #expect(meter.valueText == "42%")
        guard case .accessory(let accessory) = group.children[1] else { Issue.record("second child not an accessory"); return }
        #expect(accessory.text == "Pro")
        #expect(group.actions.map(\.title) == ["Refresh"])
    }

    @Test func aGroupSymbolOutsideTheAllowlistIsDropped() throws {
        let root = try decodeV2(#"{"type":"Group","title":"t","sfSymbol":"apple.logo","children":[]}"#)
        guard case .group(let group) = root.nodes[0] else { Issue.record("not a group"); return }
        #expect(group.sfSymbol == nil)
    }

    @Test func aGroupWithAListChildIsRefused() {
        let child = #"{"type":"List","sections":[]}"#
        #expect(throws: DecodingError.self) { try decodeV2(groupJSON(children: child)) }
    }

    @Test func aGroupWithASegmentsMeterChildIsRefused() {
        let child = #"{"type":"Meter","segments":[{"value":1,"tone":"success"}],"max":2}"#
        #expect(throws: DecodingError.self) { try decodeV2(groupJSON(children: child)) }
    }

    @Test func groupAndValueMeterAreRefusedUnderAPIVersionOne() {
        #expect(throws: DecodingError.self) { try decodeV2(groupJSON(), apiVersion: 1) }
        #expect(throws: DecodingError.self) { try decodeV2(sessionMeter, apiVersion: 1) }
    }

    @Test func aDecoderWithoutAnAPIVersionTreatsTheTreeAsVersionOne() {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LeoPluginSlotRoot.self, from: Data(sessionMeter.utf8)) }
    }

    @Test func groupAndValueMeterRoundTrip() throws {
        let root = try decodeV2("[\(groupJSON()),\(sessionMeter)]")
        let decoder = JSONDecoder()
        decoder.userInfo[LeoPluginNodeDecoding.apiVersionKey] = 2
        #expect(try decoder.decode(LeoPluginSlotRoot.self, from: JSONEncoder().encode(root)) == root)
    }

    @Test func groupChildrenCountTowardTheNodeBudget() throws {
        let children = Array(repeating: sessionMeter, count: 3).joined(separator: ",")
        let root = try decodeV2(groupJSON(children: children))
        // Group + accessory + three meters.
        #expect(root.nodes[0].nodeCount == 5)
        let tooMany = Array(repeating: #"{"type":"Accessory","text":"x"}"#, count: LeoPluginNodeLimits.maxNodes).joined(separator: ",")
        #expect(throws: DecodingError.self) { try decodeV2(groupJSON(children: tooMany)) }
    }
}

extension LeoPluginTreeDiffTests {
    @Test func aChangedGroupIsUpdatedInPlaceNotReplaced() {
        let before = LeoPluginNode.group(.init(title: "a", children: [.meter(.init(label: "Session", value: 0.1, tone: .success))]))
        let after = LeoPluginNode.group(.init(title: "a", children: [.meter(.init(label: "Session", value: 0.9, tone: .failure))]))
        let ops = LeoPluginTreeDiff.diff(old: [before], new: [after])
        #expect(ops == [.replaceNode(index: 0, node: after)])  // not .replaceRoot
    }
}

extension LeoPluginSectionRowsTests {
    @Test func aGroupAndARootValueMeterEachDrawOneRow() {
        let group = LeoPluginNode.Group(title: "codex", children: [.meter(.init(label: "Weekly", value: 0.5, tone: .success))])
        let meter = LeoPluginNode.ValueMeter(label: "Session", value: 0.2, tone: .success)
        let rows = LeoPluginSectionRows.make(from: [.group(group), .valueMeter(meter)])
        #expect(rows == [.group(id: "g0", group), .meter(id: "m1", meter)])
    }
}

extension LeoPluginWireTests {
    @Test func theHostMessageDecoderGatesV2NodesByTheCallersAPIVersion() throws {
        let frame = Data(#"{"call":"render","slot":{"kind":"section","id":"usage"},"node":\#(sessionMeter)}"#.utf8)
        #expect(throws: DecodingError.self) { try LeoPluginHostMessage.decode(frame: frame, apiVersion: 1) }
        guard case .request = try LeoPluginHostMessage.decode(frame: frame, apiVersion: 2) else {
            Issue.record("expected a request")
            return
        }
    }
}
