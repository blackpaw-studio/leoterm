import LeoKit
import SwiftUI

/// Slot 2 on an agent row: the plugins' accessories (symbol, a few
/// characters, a semantic colour), at most two, then "+N". Sits on the name
/// line beside the browser globe, so the row never gets taller.
struct LeoPluginRowAccessories: View {
    let host: LeoHostID
    let agent: String
    var isSelected = false
    @Environment(\.leoPluginSurfaces) private var surfaces

    var body: some View {
        if let surfaces {
            Watching(surfaces: surfaces, host: host, agent: agent, isSelected: isSelected)
        }
    }

    private struct Watching: View {
        @ObservedObject var surfaces: LeoPluginSurfaces
        let host: LeoHostID
        let agent: String
        let isSelected: Bool

        var body: some View {
            let layout = surfaces.accessoryLayout(host: host, agent: agent)
            if !layout.chips.isEmpty {
                HStack(spacing: 5) {
                    ForEach(layout.chips, id: \.pluginID) { chip in
                        ChipView(chip: chip, isSelected: isSelected)
                    }
                    if let overflow = layout.overflow {
                        Text(overflow.label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(LeoInk.secondary.style(isSelected: isSelected))
                            .fixedSize()
                            .help(overflow.help)
                            .accessibilityLabel("\(overflow.count) more plugin badges")
                    }
                }
            }
        }
    }

    private struct ChipView: View {
        let chip: LeoPluginAccessoryLayout.Chip
        let isSelected: Bool

        var body: some View {
            HStack(spacing: 2) {
                if let symbol = chip.sfSymbol { Image(systemName: symbol) }
                if !chip.text.isEmpty { Text(chip.text).lineLimit(1) }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(LeoPluginRenderStyle.ink(for: chip.color).style(isSelected: isSelected))
            .fixedSize()
            .help(chip.help)
            .accessibilityLabel(chip.help)
        }
    }
}
