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
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text(sample.name).fontWeight(.medium)
                        Spacer(minLength: 8)
                        previewCluster(sample.meters)
                    }
                    .frame(minHeight: 20)
                    LeoMachineMeterRow(meters: sample.meters, style: setting.style).padding(.leading, 14)
                }
            }
        }
        .frame(width: 260)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }

    /// The same meters the sidebar's machine headers draw.
    @ViewBuilder private func previewCluster(_ meters: LeoMachineHeaderPresentation.Meters) -> some View {
        if setting.style.showsMeters {
            LeoMachineMeterCluster(meters: meters, style: setting.style)
        } else {
            Text("No meters").font(.caption).foregroundStyle(.secondary)
        }
    }

    private static let samples: [(name: String, meters: LeoMachineHeaderPresentation.Meters)] = [
        ("This Mac", meters(cpu: 23, memory: 0.62, disk: 0.41)),
        ("Dionysus", meters(cpu: 12, memory: 0.84, disk: 0.93)),
    ]

    private static func meters(cpu: Double, memory: Double, disk: Double) -> LeoMachineHeaderPresentation.Meters {
        let gb: Int64 = 1_073_741_824
        let sample = LeoMachineStats(
            sampledAt: Date(), cpu: .init(percent: cpu, cores: 8),
            memory: .init(usedBytes: Int64(memory * 16 * Double(gb)), totalBytes: 16 * gb),
            disk: .init(path: "/", usedBytes: Int64(disk * 512 * Double(gb)), totalBytes: 512 * gb)
        )
        return LeoMachineHeaderPresentation.meters(
            connected: true, style: .capsules, features: LeoDaemonFeatures(["machine_stats"]), stats: sample, now: sample.sampledAt
        )
    }
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
