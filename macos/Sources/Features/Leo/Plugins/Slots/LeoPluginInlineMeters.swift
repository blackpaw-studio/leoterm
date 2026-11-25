import AppKit
import LeoKit
import SwiftUI

/// The label and value column widths shared by every `inline` Group in a
/// slot, so each bar starts at the same x in every row. Measured from the
/// widest label and valueText among those Groups' meters; valueText is
/// measured semibold with tabular digits, its widest form.
struct LeoPluginInlineMeterColumns: Equatable {
    let label: CGFloat
    let value: CGFloat

    static let font = NSFont.systemFont(ofSize: 11)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    static func measure(_ rows: [LeoPluginSectionRows.Row]) -> LeoPluginInlineMeterColumns? {
        let meters = rows.flatMap { row -> [LeoPluginNode.ValueMeter] in
            guard case .group(_, let group) = row, group.meterLayout == .inline else { return [] }
            return group.children.compactMap { if case .meter(let meter) = $0 { meter } else { nil } }
        }
        guard !meters.isEmpty else { return nil }
        func widest(_ texts: [String], _ font: NSFont) -> CGFloat {
            texts.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        }
        return LeoPluginInlineMeterColumns(
            label: widest(meters.map(\.label), font),
            value: widest(meters.map { $0.valueText ?? "" }, valueFont))
    }
}

/// A Group's children when `meterLayout` is `inline`: the meters share one
/// line in equal-width columns while every column can still show its value and
/// a usable bar. When they can't (a narrow sidebar, 3+ meters), the whole
/// group falls back to the stacked rows. Accessory children draw below either way.
struct LeoPluginInlineMeterChildren: View {
    let children: [LeoPluginNode.Group.Child]
    let columns: LeoPluginInlineMeterColumns?
    /// The slot's shared label column, for the stacked fallback.
    var stackedLabelColumn: CGFloat?

    private static let columnGap: CGFloat = 12

    private var meters: [LeoPluginNode.ValueMeter] {
        children.compactMap { if case .meter(let meter) = $0 { meter } else { nil } }
    }

    private var accessories: [LeoPluginNode.Accessory] {
        children.compactMap { if case .accessory(let accessory) = $0 { accessory } else { nil } }
    }

    var body: some View {
        if !meters.isEmpty {
            ViewThatFits(in: .horizontal) {
                LeoPluginInlineMeterRowsLayout(gap: Self.columnGap) {
                    ForEach(Array(meters.enumerated()), id: \.offset) { _, meter in
                        LeoPluginInlineMeter(meter: meter, columns: columns)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(meters.enumerated()), id: \.offset) { _, meter in
                        LeoPluginSectionMeter(meter: meter, labelColumn: stackedLabelColumn)
                    }
                }
            }
        }
        ForEach(Array(accessories.enumerated()), id: \.offset) { _, accessory in
            LeoPluginSectionAccessory(accessory: accessory)
        }
    }
}

/// Lays inline meters out as equal columns. Its ideal width is the narrowest
/// at which every column is still usable, so `ViewThatFits` falls back to the
/// stacked rows below that.
struct LeoPluginInlineMeterRowsLayout: Layout {
    var gap: CGFloat

    /// Width of each of `count` equal columns in `width`.
    static func columnWidth(width: CGFloat, count: Int, gap: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return max(0, (width - gap * CGFloat(count - 1)) / CGFloat(count))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        if let width = proposal.width, width.isFinite {
            let column = Self.columnWidth(width: width, count: subviews.count, gap: gap)
            let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: height)
        }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(subviews.count - 1)
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = Self.columnWidth(width: bounds.width, count: subviews.count, gap: gap)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * (column + gap), y: bounds.minY),
                anchor: .topLeading, proposal: ProposedViewSize(width: column, height: nil))
        }
    }
}

/// One inline meter: label, bar, value on a line, with the detail under the
/// bar in 11 pt secondary text. No detail, no extra height. The shared
/// columns are upper bounds: the label truncates, then the bar shrinks, and
/// the value never does.
struct LeoPluginInlineMeter: View {
    let meter: LeoPluginNode.ValueMeter
    let columns: LeoPluginInlineMeterColumns?

    private var presentation: LeoPluginValueMeterPresentation { LeoPluginValueMeterPresentation(meter) }

    var body: some View {
        LeoPluginInlineMeterLayout(labelColumn: columns?.label, valueColumn: columns?.value) {
            Text(meter.label)
                .font(Font(LeoPluginInlineMeterColumns.font))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            LeoPluginMeterTrack(meter: meter)
            Text(meter.valueText ?? "")
                .font(.system(size: 11, weight: presentation.emphasizesValueText ? .semibold : .regular).monospacedDigit())
                .fixedSize()
            if let detail = meter.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue("\(presentation.accessibilityPercent)%")
        .help(presentation.accessibilityLabel)
    }
}

/// Subviews: label, track, value, and an optional detail placed under the bar.
struct LeoPluginInlineMeterLayout: Layout {
    var labelColumn: CGFloat?
    var valueColumn: CGFloat?

    static let gap: CGFloat = 6
    static let minimumTrackWidth: CGFloat = 24
    static let minimumLabelWidth: CGFloat = 24
    static let lineSpacing: CGFloat = 1

    struct Columns: Equatable {
        let label: CGFloat
        let track: CGFloat
        let value: CGFloat
    }

    /// The narrowest width with a usable label, a usable bar and the whole value.
    static func requiredWidth(labelIdeal: CGFloat, value: CGFloat) -> CGFloat {
        min(labelIdeal, minimumLabelWidth) + value + gap * 2 + minimumTrackWidth
    }

    /// Column widths for one meter; pure, so the rules are tested without a
    /// view. Shared columns are upper bounds that give way to the bar's
    /// minimum; the value is never cut below its own width.
    static func columns(
        width: CGFloat, labelIdeal: CGFloat, labelColumn: CGFloat?, value: CGFloat, valueColumn: CGFloat?
    ) -> Columns {
        let gaps = gap * 2
        let labelFloor = min(labelIdeal, minimumLabelWidth)
        let valueWidth = min(max(value, valueColumn ?? 0), max(value, width - gaps - minimumTrackWidth - labelFloor))
        let labelWidth = max(0, min(max(labelIdeal, labelColumn ?? 0), width - valueWidth - gaps - minimumTrackWidth))
        return Columns(label: labelWidth, track: max(0, width - labelWidth - valueWidth - gaps), value: valueWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count >= 3 else { return .zero }
        let rowHeight = subviews.prefix(3).map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        let detailHeight = subviews.count > 3 ? Self.lineSpacing + subviews[3].sizeThatFits(.unspecified).height : 0
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? Self.requiredWidth(
                labelIdeal: subviews[0].sizeThatFits(.unspecified).width, value: subviews[2].sizeThatFits(.unspecified).width)
        return CGSize(width: width, height: rowHeight + detailHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 3 else { return }
        let widths = Self.columns(
            width: bounds.width, labelIdeal: subviews[0].sizeThatFits(.unspecified).width, labelColumn: labelColumn,
            value: subviews[2].sizeThatFits(.unspecified).width, valueColumn: valueColumn)
        let rowHeight = subviews.prefix(3).map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        var x = bounds.minX
        for (subview, width) in zip(subviews.prefix(3), [widths.label, widths.track, widths.value]) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY + rowHeight / 2), anchor: .leading,
                proposal: ProposedViewSize(width: width, height: nil))
            x += width + Self.gap
        }
        if subviews.count > 3 {
            let indent = widths.label + Self.gap
            subviews[3].place(
                at: CGPoint(x: bounds.minX + indent, y: bounds.minY + rowHeight + Self.lineSpacing), anchor: .topLeading,
                proposal: ProposedViewSize(width: max(0, bounds.width - indent), height: nil))
        }
    }
}
