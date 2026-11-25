import AppKit
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor
struct LeoPluginInlineMetersTests {
    private static func meter(_ label: String, _ valueText: String, detail: String? = nil) -> LeoPluginNode.Group.Child {
        .meter(.init(label: label, value: 0.4, valueText: valueText, detail: detail))
    }

    private static func group(_ layout: LeoPluginNode.Group.MeterLayout, detail: String?) -> LeoPluginNode.Group {
        .init(
            title: "claude-blackpaw-evan", sfSymbol: "sparkle",
            children: [meter("5h", "18%", detail: detail), meter("7d", "38%", detail: detail)],
            meterLayout: layout)
    }

    private static func height(of group: LeoPluginNode.Group, columns: LeoPluginInlineMeterColumns? = nil) -> CGFloat {
        let view = NSHostingView(rootView: LeoPluginSectionGroupRow(group: group, inlineColumns: columns, perform: { _ in }).frame(width: 260))
        return view.fittingSize.height
    }

    @Test func columnsAreSharedAcrossInlineGroupsAndIgnoreStackedOnes() {
        let rows: [LeoPluginSectionRows.Row] = [
            .group(id: "a", Self.group(.inline, detail: nil)),
            .group(id: "b", .init(title: "x", children: [Self.meter("Weekly session", "100%")], meterLayout: .inline)),
            .group(id: "c", .init(title: "y", children: [Self.meter("A very long stacked label", "100.0%")])),
        ]
        let columns = LeoPluginInlineMeterColumns.measure(rows)
        let alone = LeoPluginInlineMeterColumns.measure([rows[0]])
        #expect((columns?.label ?? 0) > (alone?.label ?? 0), "the widest inline label sets the shared column")
        #expect((columns?.value ?? 0) >= (alone?.value ?? 0))
        let stackedOnly = LeoPluginInlineMeterColumns.measure([rows[2]])
        #expect(stackedOnly == nil)
    }

    @Test func aMeterDetailAddsHeightAndNoDetailAddsNone() {
        let withDetail = Self.height(of: Self.group(.inline, detail: "resets in 34m"))
        let without = Self.height(of: Self.group(.inline, detail: nil))
        #expect(withDetail > without)
        let blank = Self.height(of: Self.group(.inline, detail: ""))
        #expect(blank == without)
    }

    @Test func inlineMetersShareALineSoTheGroupIsShorterThanStacked() {
        let inline = Self.height(of: Self.group(.inline, detail: nil))
        let stacked = Self.height(of: Self.group(.stacked, detail: nil))
        #expect(inline < stacked)
    }
}
