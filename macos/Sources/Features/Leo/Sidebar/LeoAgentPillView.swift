import SwiftUI

/// Draws a `LeoAgentPill`: a capsule with a symbol and a word, the tint at
/// a low-opacity fill and in the text. On a selected row it is white on a
/// white wash so it keeps contrast against the selection.
struct LeoAgentPillView: View {
    let pill: LeoAgentPill
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: LeoAgentRowMetrics.pillSymbolSpacing) {
            Image(systemName: pill.symbolName)
            Text(pill.word)
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, LeoAgentRowMetrics.pillHorizontalPadding)
        .frame(height: LeoAgentRowMetrics.pillHeight)
        .foregroundStyle(isSelected ? Color.white : pill.tint.color)
        .background(fill)
        .overlay { outline }
        .layoutPriority(1)
        .help(pill.help ?? "")
        // The name's label already says the state.
        .accessibilityHidden(true)
    }

    @ViewBuilder private var fill: some View {
        if isSelected {
            Capsule().fill(Color.white.opacity(LeoAgentPill.selectedFillOpacity))
        } else if !pill.isOutlined {
            Capsule().fill(pill.tint.color.opacity(LeoAgentPill.fillOpacity(isDark: colorScheme == .dark)))
        }
    }

    @ViewBuilder private var outline: some View {
        if pill.isOutlined {
            Capsule().strokeBorder(isSelected ? Color.white.opacity(0.6) : pill.tint.color.opacity(0.6), lineWidth: 1)
        }
    }
}
