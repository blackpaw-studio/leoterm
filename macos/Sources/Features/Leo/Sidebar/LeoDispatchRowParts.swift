import SwiftUI

/// The role as a small tinted chip: the tint at a low-opacity fill, the text
/// in the tint.
struct LeoRoleChipView: View {
    static let cornerRadius: CGFloat = 4
    static let horizontalPadding: CGFloat = 5
    static let verticalPadding: CGFloat = 1

    let chip: LeoDispatchRowPresentation.RoleChip
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var style: LeoTintedStyle {
        LeoTintedStyle(tint: chip.tint, isSelected: isSelected, isDark: colorScheme == .dark)
    }

    var body: some View {
        Text(chip.text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(style.content.color)
            .lineLimit(1)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .background(style.fillColor, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// The dispatch row's trailing dot and elapsed time (or status word). A
/// running dot pulses unless Reduce Motion is on.
struct LeoDispatchStatusView: View {
    let status: LeoDispatchRowPresentation.Status
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        HStack(spacing: 5) {
            dot
            Text(status.text)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(textStyle)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityHidden(true)
    }

    private var dot: some View {
        let tint = style(for: status.dot.tint).content.color
        return ZStack {
            if status.dot.isHollow {
                Circle().strokeBorder(tint, lineWidth: 1)
            } else {
                Circle().fill(tint)
            }
        }
        .frame(width: LeoDispatchRowView.dotSize, height: LeoDispatchRowView.dotSize)
        .opacity(isDimmed ? LeoDispatchRowView.pulseDimmedOpacity : 1)
        .task(id: shouldPulse) { setPulsing(shouldPulse) }
    }

    private func style(for tint: LeoTint) -> LeoTintedStyle {
        LeoTintedStyle(tint: tint, isSelected: isSelected, isDark: colorScheme == .dark)
    }

    /// Elapsed time is tertiary; the stalled copy takes its tint (white when selected).
    private var textStyle: AnyShapeStyle {
        status.textTint.map { AnyShapeStyle(style(for: $0).content.color) } ?? AnyShapeStyle(.tertiary)
    }

    private var shouldPulse: Bool { status.dot.pulses && !reduceMotion }

    /// A zero-length animation is what ends a repeating one.
    private func setPulsing(_ pulsing: Bool) {
        let animation: Animation = pulsing
            ? .easeInOut(duration: LeoDispatchRowView.pulseDuration).repeatForever(autoreverses: true)
            : .linear(duration: 0)
        withAnimation(animation) { isDimmed = pulsing }
    }
}
