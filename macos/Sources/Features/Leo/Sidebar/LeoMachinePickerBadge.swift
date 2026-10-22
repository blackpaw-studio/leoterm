import AppKit
import SwiftUI
import LeoKit

/// The picker row's leading badge: the machine's status dot and, for a
/// connected machine, its meters in the chosen style (Rings stay rings;
/// Capsules, Bars and Numbers read as mini capsules). A menu row takes an
/// image, so the badge is rendered to one.
@MainActor enum LeoMachinePickerBadge {
    static func image(for option: SpawnMachineOption, style: LeoStatsStyle, scale: CGFloat = 2) -> NSImage? {
        let renderer = ImageRenderer(content: LeoMachinePickerBadgeView(option: option, style: style))
        renderer.scale = scale
        return renderer.nsImage
    }
}

struct LeoMachinePickerBadgeView: View {
    let option: SpawnMachineOption
    let style: LeoStatsStyle

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            LeoMachineMeterCluster(meters: meters, style: style == .rings ? .rings : .capsules)
        }
        .fixedSize()
    }

    private var dotColor: Color {
        switch option.status {
        case .connected: LeoTint.green.color
        case .connecting: LeoTint.orange.color
        case .failed: LeoTint.red.color
        case .disabled: Color(nsColor: .tertiaryLabelColor)
        }
    }

    private var meters: LeoMachineHeaderPresentation.Meters {
        LeoMachineHeaderPresentation.meters(
            connected: option.status == .connected, style: style, features: LeoDaemonFeatures(["machine_stats"]),
            stats: option.stats, now: option.stats?.sampledAt ?? Date()
        )
    }
}
