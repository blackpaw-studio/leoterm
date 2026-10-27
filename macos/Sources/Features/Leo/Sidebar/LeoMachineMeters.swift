import AppKit
import SwiftUI
import LeoKit

extension LeoStatsStyle {
    /// Bars and Numbers need a second row under the machine's name;
    /// Capsules and Rings fit in the header row.
    var usesSecondRow: Bool { self == .bars || self == .numbers }
}

private enum LeoMeterMetrics {
    static let capsuleSize = CGSize(width: 10, height: 20)
    static let ringDiameter: CGFloat = 20
    static let ringLineWidth: CGFloat = 2.5
    static let capsuleSpacing: CGFloat = 3
    static let ringSpacing: CGFloat = 5
    static let dimmedOpacity = 0.4
}

extension LeoMeterLevel {
    /// Flat fills, never gradients: blue below 80%, amber from 80%, red from 90%.
    var fill: Color {
        switch self {
        case .normal: Color(nsColor: .systemBlue)
        case .warning: Color(nsColor: .systemOrange)
        case .critical: Color(nsColor: .systemRed)
        }
    }
}

/// What a meter style draws for one machine: the placeholders when there
/// are no values, the meters themselves otherwise.
private struct LeoMeterContent {
    let meters: [LeoMachineHeaderPresentation.Meter]
    let isPlaceholder: Bool
    let tooltip: String?

    init?(_ meters: LeoMachineHeaderPresentation.Meters) {
        switch meters {
        case .hidden:
            return nil
        case .unavailable(let tooltip):
            self.meters = LeoMachineHeaderPresentation.Metric.allCases.map {
                .init(metric: $0, fraction: nil, level: .normal, valueText: LeoMachineHeaderPresentation.noValue, tooltip: tooltip)
            }
            isPlaceholder = true
            self.tooltip = tooltip
        case .values(let values):
            self.meters = values
            isPlaceholder = false
            tooltip = nil
        }
    }
}

/// Capsules and Rings: one cluster that sits in the header row.
struct LeoMachineMeterCluster: View {
    let meters: LeoMachineHeaderPresentation.Meters
    let style: LeoStatsStyle

    var body: some View {
        if let content = LeoMeterContent(meters), style == .capsules || style == .rings {
            HStack(spacing: style == .rings ? LeoMeterMetrics.ringSpacing : LeoMeterMetrics.capsuleSpacing) {
                ForEach(content.meters) { meter in
                    Group {
                        if style == .capsules { LeoCapsuleMeter(meter: meter) } else { LeoRingMeter(meter: meter) }
                    }
                    .help(meter.tooltip)
                }
            }
            .opacity(content.isPlaceholder ? LeoMeterMetrics.dimmedOpacity : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LeoMachineMeterAccessibility.label(content.meters))
        }
    }
}

/// Bars and Numbers: a second row under the header.
struct LeoMachineMeterRow: View {
    let meters: LeoMachineHeaderPresentation.Meters
    let style: LeoStatsStyle

    var body: some View {
        if let content = LeoMeterContent(meters), style.usesSecondRow {
            Group {
                if style == .bars {
                    HStack(spacing: 8) {
                        ForEach(content.meters) { meter in LeoBarMeter(meter: meter).help(meter.tooltip) }
                    }
                } else {
                    HStack(spacing: 4) {
                        ForEach(Array(content.meters.enumerated()), id: \.element.id) { index, meter in
                            if index > 0 { Text("·").foregroundStyle(.tertiary) }
                            LeoNumberMeter(meter: meter).help(meter.tooltip)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .font(.caption2)
            .opacity(content.isPlaceholder ? LeoMeterMetrics.dimmedOpacity : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LeoMachineMeterAccessibility.label(content.meters))
        }
    }
}

enum LeoMachineMeterAccessibility {
    static func label(_ meters: [LeoMachineHeaderPresentation.Meter]) -> String {
        meters.map { "\($0.metric.title) \($0.valueText)" }.joined(separator: ", ")
    }
}

// MARK: - Styles

/// The stacked three-letter label beside a capsule.
private struct LeoMeterLabel: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(text), id: \.self) { Text(String($0)) }
        }
        .font(.system(size: 6, weight: .bold))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

private struct LeoCapsuleMeter: View {
    let meter: LeoMachineHeaderPresentation.Meter

    var body: some View {
        HStack(spacing: 1) {
            LeoMeterLabel(text: meter.metric.shortLabel)
            ZStack(alignment: .bottom) {
                Capsule().strokeBorder(.secondary.opacity(0.7), lineWidth: 1)
                if let fraction = meter.fraction {
                    Capsule()
                        .fill(meter.level.fill)
                        .frame(height: max(LeoMeterMetrics.capsuleSize.width, LeoMeterMetrics.capsuleSize.height * fraction))
                        .padding(1.5)
                        .mask(alignment: .bottom) {
                            Rectangle().frame(height: LeoMeterMetrics.capsuleSize.height * fraction)
                        }
                }
            }
            .frame(width: LeoMeterMetrics.capsuleSize.width, height: LeoMeterMetrics.capsuleSize.height)
        }
    }
}

private struct LeoRingMeter: View {
    let meter: LeoMachineHeaderPresentation.Meter

    var body: some View {
        // Strokes are centred on the path, so inset by half the line width to
        // keep the ink inside the ring's frame (B-309, B-310).
        let inset = LeoMeterMetrics.ringLineWidth / 2
        return ZStack {
            Circle().inset(by: inset).stroke(.secondary.opacity(0.3), lineWidth: LeoMeterMetrics.ringLineWidth)
            if let fraction = meter.fraction {
                Circle()
                    .inset(by: inset)
                    .trim(from: 0, to: fraction)
                    .stroke(meter.level.fill, style: StrokeStyle(lineWidth: LeoMeterMetrics.ringLineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            Text(ringText).font(.system(size: 7, weight: .semibold)).monospacedDigit()
        }
        .frame(width: LeoMeterMetrics.ringDiameter, height: LeoMeterMetrics.ringDiameter)
    }

    /// Just the number inside the ring: "41", not "41%".
    private var ringText: String {
        meter.fraction == nil || meter.metric != .cpu ? meter.fraction.map { "\(Int(($0 * 100).rounded()))" } ?? "—" : meter.valueText.replacingOccurrences(of: "%", with: "")
    }
}

private struct LeoBarMeter: View {
    let meter: LeoMachineHeaderPresentation.Meter

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(meter.metric.shortLabel).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(percentText).monospacedDigit().foregroundStyle(meter.level == .normal ? Color.primary : meter.level.fill)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.25))
                    if let fraction = meter.fraction {
                        Capsule().fill(meter.level.fill).frame(width: proxy.size.width * fraction)
                    }
                }
            }
            .frame(height: 3)
        }
    }

    private var percentText: String { meter.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
}

private struct LeoNumberMeter: View {
    let meter: LeoMachineHeaderPresentation.Meter

    var body: some View {
        HStack(spacing: 3) {
            Text(meter.metric.shortLabel).foregroundStyle(.secondary)
            Text(meter.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .monospacedDigit()
                .foregroundStyle(meter.level == .normal ? Color.primary : meter.level.fill)
        }
    }
}
