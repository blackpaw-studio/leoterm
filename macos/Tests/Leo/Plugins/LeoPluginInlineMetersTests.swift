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

    // MARK: Narrow sidebars

    /// The narrowest sidebar's row content: 200 pt less the row padding and the group indent.
    private static let narrowWidth: CGFloat = 200 - 8 - 22

    private static func height(of group: LeoPluginNode.Group, width: CGFloat) -> CGFloat {
        let view = NSHostingView(rootView: LeoPluginSectionGroupRow(group: group, inlineColumns: nil, perform: { _ in }).frame(width: width))
        return view.fittingSize.height
    }

    private static func group(_ layout: LeoPluginNode.Group.MeterLayout, labels: [String]) -> LeoPluginNode.Group {
        .init(
            title: "claude", sfSymbol: "sparkle",
            children: labels.map { meter($0, "100%") }, meterLayout: layout)
    }

    @Test func longLabelsAtTheNarrowestSidebarFallBackToStackedRows() {
        let labels = ["Session usage", "Weekly usage"]
        let inline = Self.height(of: Self.group(.inline, labels: labels), width: Self.narrowWidth)
        let stacked = Self.height(of: Self.group(.stacked, labels: labels), width: Self.narrowWidth)
        #expect(inline == stacked, "columns that can't show the value fall back to stacked")
    }

    @Test func threeMetersAtTheNarrowestSidebarFallBackToStackedRows() {
        let labels = ["5h", "7d", "30d"]
        let inline = Self.height(of: Self.group(.inline, labels: labels), width: Self.narrowWidth)
        let stacked = Self.height(of: Self.group(.stacked, labels: labels), width: Self.narrowWidth)
        #expect(inline == stacked)
    }

    @Test func shortLabelsStayInlineWhenTheyFit() {
        let labels = ["5h", "7d"]
        let inline = Self.height(of: Self.group(.inline, labels: labels), width: 260)
        let stacked = Self.height(of: Self.group(.stacked, labels: labels), width: 260)
        #expect(inline < stacked)
    }

    @Test(arguments: [60.0, 80, 120, 200, 400])
    func columnsNeverCutTheValueOrOverlap(width: Double) {
        let columns = LeoPluginInlineMeterLayout.columns(
            width: CGFloat(width), labelIdeal: 60, labelColumn: 90, value: 30, valueColumn: 40)
        #expect(columns.value >= 30, "the value keeps at least its own width")
        #expect(columns.label >= 0 && columns.track >= 0)
        let gaps = LeoPluginInlineMeterLayout.gap * 2
        let used = columns.label + columns.track + columns.value + gaps
        // Past the minimum bar the columns sum to the width; below it the value still wins.
        #expect(used <= max(CGFloat(width), LeoPluginInlineMeterLayout.requiredWidth(labelIdeal: 60, value: 30)))
    }

    @Test func sharedColumnsAreUpperBoundsThatGiveWayToTheBar() {
        let roomy = LeoPluginInlineMeterLayout.columns(width: 300, labelIdeal: 30, labelColumn: 60, value: 28, valueColumn: 40)
        #expect(roomy.label == 60 && roomy.value == 40, "shared columns apply when there is room")
        let tight = LeoPluginInlineMeterLayout.columns(width: 100, labelIdeal: 30, labelColumn: 60, value: 28, valueColumn: 40)
        #expect(tight.track >= LeoPluginInlineMeterLayout.minimumTrackWidth)
        #expect(tight.value >= 28)
    }
}
