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
