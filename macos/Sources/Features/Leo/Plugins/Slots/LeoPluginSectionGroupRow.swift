import LeoKit
import SwiftUI

/// A `Group` as a compact sidebar row: symbol, regular-weight title and a trailing
/// accessory, then its meters indented under the title. The subtitle shows
/// only when there are no meters. A click runs the first action; the context
/// menu has them all. Metrics follow `docs/designs/usage-plugin/design.md`.
struct LeoPluginSectionGroupRow: View {
    let group: LeoPluginNode.Group
    /// The slot's shared meter label column (`LeoPluginSectionMeter.labelColumn`).
    var labelColumn: CGFloat?
    /// The slot's shared label and value columns for `inline` groups.
    var inlineColumns: LeoPluginInlineMeterColumns?
    let perform: (LeoPluginAction) -> Void

    private static let symbolColumn: CGFloat = 16
    private static let symbolGap: CGFloat = 6
    private static var indent: CGFloat { symbolColumn + symbolGap }

    private var entries: [LeoPluginActionEntry] { LeoPluginActionPresentation.entries(for: group.actions) }

    private var hasMeters: Bool {
        group.children.contains { if case .meter = $0 { true } else { false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            if !hasMeters, let subtitle = group.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.leading, Self.indent)
            }
            children
                .padding(.leading, Self.indent)
            if !hasMeters, let first = entries.first {
                LeoPluginInlineActionButton(entry: first) { perform(first.action) }
                    .padding(.leading, Self.indent)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: LeoDispatchRowMetrics.terminalRowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if let first = entries.first { perform(first.action) } }
        .contextMenu {
            ForEach(entries, id: \.index) { entry in
                Button { perform(entry.action) } label: { Label(entry.title, systemImage: entry.sfSymbol) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityActions {
            ForEach(entries, id: \.index) { entry in
                Button(entry.title) { perform(entry.action) }
            }
        }
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder private var children: some View {
        if group.meterLayout == .inline {
            LeoPluginInlineMeterChildren(children: group.children, columns: inlineColumns)
        } else {
            ForEach(Array(group.children.enumerated()), id: \.offset) { _, child in
                switch child {
                case .meter(let meter): LeoPluginSectionMeter(meter: meter, labelColumn: labelColumn)
                case .accessory(let accessory): LeoPluginSectionAccessory(accessory: accessory)
                }
            }
        }
    }

    /// Title, then the subtitle even while meters hide it (the plugin puts
    /// the account's kind there, so Claude vs Codex is announced), then state.
    private var accessibilityLabel: String {
        [group.title, group.subtitle, group.accessory?.text]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var header: some View {
        HStack(spacing: Self.symbolGap) {
            Image(systemName: group.sfSymbol ?? "circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: Self.symbolColumn)
                .opacity(group.sfSymbol == nil ? 0 : 1)
                .accessibilityHidden(true)
            Text(group.title)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(group.title)
            Spacer(minLength: 0)
            if let accessory = group.accessory { LeoPluginSectionAccessory(accessory: accessory) }
        }
    }
}

/// A value `Meter` as a sidebar row on its own (a slot root), at the Group's indent.
struct LeoPluginSectionMeterRow: View {
    let meter: LeoPluginNode.ValueMeter
    var labelColumn: CGFloat?

    var body: some View {
        LeoPluginSectionMeter(meter: meter, labelColumn: labelColumn)
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: LeoDispatchRowMetrics.terminalRowHeight, alignment: .leading)
            .listRowInsets(EdgeInsets())
    }
}

/// The compact meter: label | 5 pt track | valueText, detail below in caption.
/// valueText never truncates; the label gives way first, then hides.
struct LeoPluginSectionMeter: View {
    let meter: LeoPluginNode.ValueMeter
    /// The widest label in the slot, so tracks line up across Groups; nil sizes to this label.
    var labelColumn: CGFloat?

    private static let minimumTrackWidth: CGFloat = 48
    private static let labelFont = NSFont.systemFont(ofSize: 11)

    /// The shared label column for a section's rows: its widest meter label.
    static func labelColumn(for rows: [LeoPluginSectionRows.Row]) -> CGFloat? {
        let labels = rows.flatMap { row -> [String] in
            switch row {
            case .group(_, let group): group.children.compactMap { if case .meter(let meter) = $0 { meter.label } else { nil } }
            case .meter(_, let meter): [meter.label]
            default: []
            }
        }
        return labels.map { ceil(($0 as NSString).size(withAttributes: [.font: labelFont]).width) }.max()
    }

    private var presentation: LeoPluginValueMeterPresentation { LeoPluginValueMeterPresentation(meter) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            LeoPluginMeterRowLayout(labelColumn: labelColumn, minimumTrackWidth: Self.minimumTrackWidth) {
                Text(meter.label)
                    .font(Font(Self.labelFont))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                track
                Text(meter.valueText ?? "")
                    .font(.system(size: 11, weight: presentation.emphasizesValueText ? .semibold : .regular).monospacedDigit())
                    .fixedSize()
            }
            if let detail = meter.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10))
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

    private var track: some View { LeoPluginMeterTrack(meter: meter) }
}

/// The 5 pt capsule track and its tinted fill, shared by the stacked and inline meters.
struct LeoPluginMeterTrack: View {
    let meter: LeoPluginNode.ValueMeter
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 5

    private var presentation: LeoPluginValueMeterPresentation { LeoPluginValueMeterPresentation(meter) }

    var body: some View {
        GeometryReader { proxy in
            let fill = presentation.fillWidth(trackWidth: Double(proxy.size.width), trackHeight: Double(Self.height))
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: contrast == .increased ? .tertiaryLabelColor : .quaternaryLabelColor))
                Capsule()
                    .fill(Color(nsColor: LeoPluginRenderStyle.color(for: presentation.tone)))
                    .frame(width: CGFloat(fill))
            }
            .clipShape(Capsule())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: meter.value)
        }
        .frame(height: Self.height)
    }
}

/// An Accessory in a sidebar Group: 11 pt medium in its tone.
struct LeoPluginSectionAccessory: View {
    let accessory: LeoPluginNode.Accessory

    var body: some View {
        HStack(spacing: 2) {
            if let symbol = accessory.sfSymbol { Image(systemName: symbol) }
            if !accessory.text.isEmpty { Text(accessory.text).lineLimit(1) }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(LeoPluginRenderStyle.ink(for: accessory.color).style(isSelected: false))
        .fixedSize()
        .help(accessory.help ?? accessory.text)
    }
}

/// A Group without meters shows its first action as a small capsule button.
struct LeoPluginInlineActionButton: View {
    let entry: LeoPluginActionEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Not a Label: a sidebar List gives a Label's icon its own wide
            // column, which pulls the symbol away from the title.
            HStack(spacing: 4) {
                Image(systemName: entry.sfSymbol)
                Text(entry.title)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
        }
        .buttonStyle(.plain)
    }
}

/// label | track | valueText. The label column is the shared width (or the
/// label's own), capped at 40% of the row; valueText never truncates; the
/// track takes the rest, and below its minimum the label gives way first.
struct LeoPluginMeterRowLayout: Layout {
    var labelColumn: CGFloat?
    var minimumTrackWidth: CGFloat
    var gap: CGFloat = 8
    var labelCap: CGFloat = 0.4

    /// Column widths for one row; pure, so the rules are tested without a view.
    struct Columns: Equatable {
        let label: CGFloat
        let track: CGFloat
        let value: CGFloat
    }

    static func columns(
        width: CGFloat, labelIdeal: CGFloat, labelColumn: CGFloat?, value: CGFloat,
        gap: CGFloat = 8, labelCap: CGFloat = 0.4, minimumTrackWidth: CGFloat
    ) -> Columns {
        let gaps = value > 0 ? gap * 2 : gap
        var label = labelColumn ?? labelIdeal
        if width.isFinite {
            label = min(label, width * labelCap, max(0, width - value - gaps - minimumTrackWidth))
        }
        let track = width.isFinite ? max(0, width - label - value - gaps) : minimumTrackWidth
        return Columns(label: label, track: track, value: value)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        if let width = proposal.width, width.isFinite { return CGSize(width: width, height: height) }
        let ideal = columns(width: .infinity, subviews: subviews)
        let gaps = ideal.value > 0 ? gap * 2 : gap
        return CGSize(width: ideal.label + gaps + ideal.track + ideal.value, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let widths = columns(width: bounds.width, subviews: subviews)
        var x = bounds.minX
        for (subview, width) in zip(subviews, [widths.label, widths.track, widths.value]) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: nil))
            x += width + (width > 0 ? gap : 0)
        }
    }

    private func columns(width: CGFloat, subviews: Subviews) -> Columns {
        Self.columns(
            width: width, labelIdeal: subviews[0].sizeThatFits(.unspecified).width, labelColumn: labelColumn,
            value: subviews[2].sizeThatFits(.unspecified).width, gap: gap, labelCap: labelCap, minimumTrackWidth: minimumTrackWidth)
    }
}
