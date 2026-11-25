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
/// line in equal-width columns; any accessory children draw below as in the
/// stacked layout.
struct LeoPluginInlineMeterChildren: View {
    let children: [LeoPluginNode.Group.Child]
    let columns: LeoPluginInlineMeterColumns?

    private static let columnGap: CGFloat = 12

    private var meters: [LeoPluginNode.ValueMeter] {
        children.compactMap { if case .meter(let meter) = $0 { meter } else { nil } }
    }

    private var accessories: [LeoPluginNode.Accessory] {
        children.compactMap { if case .accessory(let accessory) = $0 { accessory } else { nil } }
    }

    var body: some View {
        if !meters.isEmpty {
            HStack(alignment: .top, spacing: Self.columnGap) {
                ForEach(Array(meters.enumerated()), id: \.offset) { _, meter in
                    LeoPluginInlineMeter(meter: meter, columns: columns)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        ForEach(Array(accessories.enumerated()), id: \.offset) { _, accessory in
            LeoPluginSectionAccessory(accessory: accessory)
        }
    }
}

/// One inline meter: label, bar, value on a line, with the detail under the
/// bar in 11 pt secondary text. No detail, no extra height.
struct LeoPluginInlineMeter: View {
    let meter: LeoPluginNode.ValueMeter
    let columns: LeoPluginInlineMeterColumns?

    private static let gap: CGFloat = 6

    private var presentation: LeoPluginValueMeterPresentation { LeoPluginValueMeterPresentation(meter) }
    private var labelWidth: CGFloat? { columns?.label }
    private var valueWidth: CGFloat? { columns?.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: Self.gap) {
                Text(meter.label)
                    .font(Font(LeoPluginInlineMeterColumns.font))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: labelWidth, alignment: .leading)
                    .fixedSize(horizontal: labelWidth == nil, vertical: false)
                LeoPluginMeterTrack(meter: meter)
                    .frame(minWidth: 16)
                Text(meter.valueText ?? "")
                    .font(.system(size: 11, weight: presentation.emphasizesValueText ? .semibold : .regular).monospacedDigit())
                    .lineLimit(1)
                    .frame(width: valueWidth, alignment: .trailing)
                    .fixedSize(horizontal: valueWidth == nil, vertical: false)
            }
            if let detail = meter.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, (labelWidth ?? 0) + Self.gap)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue("\(presentation.accessibilityPercent)%")
        .help(presentation.accessibilityLabel)
    }
}
