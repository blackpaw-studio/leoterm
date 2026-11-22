import LeoKit
import SwiftUI

/// A `Group` as a compact sidebar row: symbol, medium title and a trailing
/// accessory, then its meters indented under the title. The subtitle shows
/// only when there are no meters. A click runs the first action; the context
/// menu has them all. Metrics follow `docs/designs/usage-plugin/design.md`.
struct LeoPluginSectionGroupRow: View {
    let group: LeoPluginNode.Group
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
            ForEach(Array(group.children.enumerated()), id: \.offset) { _, child in
                switch child {
                case .meter(let meter): LeoPluginSectionMeter(meter: meter)
                case .accessory(let accessory): LeoPluginSectionAccessory(accessory: accessory)
                }
            }
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
        .accessibilityLabel(group.title + (group.accessory.map { ", \($0.text)" } ?? ""))
        .accessibilityHint(group.subtitle ?? "")
        .accessibilityActions {
            ForEach(entries, id: \.index) { entry in
                Button(entry.title) { perform(entry.action) }
            }
        }
        .listRowInsets(EdgeInsets())
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
                .font(.system(size: 13, weight: .medium))
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

    var body: some View {
        LeoPluginSectionMeter(meter: meter)
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
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let trackHeight: CGFloat = 5
    private static let minimumTrackWidth: CGFloat = 48

    private var presentation: LeoPluginValueMeterPresentation { LeoPluginValueMeterPresentation(meter) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(meter.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
                track
                    .frame(minWidth: Self.minimumTrackWidth, maxWidth: .infinity)
                    .layoutPriority(1)
                if let valueText = meter.valueText, !valueText.isEmpty {
                    Text(valueText)
                        .font(.system(size: 11, weight: presentation.emphasizesValueText ? .semibold : .regular).monospacedDigit())
                        .fixedSize()
                        .layoutPriority(2)
                }
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

    private var track: some View {
        GeometryReader { proxy in
            let fill = presentation.fillWidth(trackWidth: Double(proxy.size.width), trackHeight: Double(Self.trackHeight))
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: contrast == .increased ? .tertiaryLabelColor : .quaternaryLabelColor))
                Capsule()
                    .fill(Color(nsColor: LeoPluginRenderStyle.color(for: presentation.tone)))
                    .frame(width: CGFloat(fill))
            }
            .clipShape(Capsule())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: meter.value)
        }
        .frame(height: Self.trackHeight)
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
            Label(entry.title, systemImage: entry.sfSymbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
        }
        .buttonStyle(.plain)
    }
}
