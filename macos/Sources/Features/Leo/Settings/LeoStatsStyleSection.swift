import LeoKit
import SwiftUI

/// Settings ▸ Machines ▸ Stats style: a segmented control and a live
/// preview. Every fill is a flat colour, never a gradient.
struct LeoStatsStyleSection: View {
    @ObservedObject var setting: LeoStatsStyleSetting

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Stats style").frame(width: 90, alignment: .trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Stats style", selection: $setting.style) {
                        ForEach(LeoStatsStyle.allCases, id: \.self) { Text($0.settingsTitle).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 380)
                    Text("Shown beside each machine in the sidebar and the machine picker. Stored on this Mac only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Text("Preview").frame(width: 90, alignment: .trailing)
                preview
            }
        }
        .padding(16)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.samples, id: \.name) { sample in
                HStack(spacing: 8) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text(sample.name).fontWeight(.medium).frame(width: 110, alignment: .leading)
                    LeoStatsStylePreviewMeters(style: setting.style, fractions: sample.fractions)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }

    private static let samples: [(name: String, fractions: [(label: String, value: Double)])] = [
        ("This Mac", [("CPU", 0.23), ("MEM", 0.62), ("DSK", 0.41)]),
        ("Dionysus", [("CPU", 0.12), ("MEM", 0.84), ("DSK", 0.93)]),
    ]
}

private extension LeoStatsStyle {
    var settingsTitle: String {
        switch self {
        case .capsules: "Capsules"
        case .bars: "Bars"
        case .rings: "Rings"
        case .numbers: "Numbers"
        case .off: "Off"
        }
    }
}

/// The preview's meters: sample fractions drawn in `style`, coloured by the
/// shared 80% / 90% thresholds.
private struct LeoStatsStylePreviewMeters: View {
    let style: LeoStatsStyle
    let fractions: [(label: String, value: Double)]

    var body: some View {
        if style.showsMeters {
            HStack(spacing: 12) {
                ForEach(fractions, id: \.label) { item in
                    meter(item.label, item.value)
                }
            }
        } else {
            Text("No meters").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func meter(_ label: String, _ value: Double) -> some View {
        let color = Self.color(for: LeoMeterLevel.level(fraction: value))
        let percent = Int((value * 100).rounded())
        switch style {
        case .capsules:
            HStack(spacing: 3) {
                caption(label)
                ZStack(alignment: .bottom) {
                    Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                    Capsule().fill(color).frame(height: 20 * value)
                }
                .frame(width: 10, height: 20)
                .clipShape(Capsule())
            }
        case .bars:
            HStack(spacing: 4) {
                caption(label)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule().fill(color).frame(width: 44 * value)
                }
                .frame(width: 44, height: 6)
            }
        case .rings:
            HStack(spacing: 4) {
                caption(label)
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                    Circle().trim(from: 0, to: value).stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
            }
        case .numbers:
            HStack(spacing: 3) {
                caption(label)
                Text("\(percent)%").font(.caption.monospacedDigit()).foregroundStyle(color)
            }
        case .off:
            EmptyView()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
    }

    private static func color(for level: LeoMeterLevel) -> Color {
        switch level {
        case .normal: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}
