import SwiftUI

/// The dispatch row's trailing elapsed time (or status word): tertiary, or
/// orange for the stalled copy (white on a selected row).
struct LeoDispatchStatusView: View {
    let status: LeoDispatchRowPresentation.Status
    let isSelected: Bool

    var body: some View {
        Text(status.text)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(ink.style(isSelected: isSelected))
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }

    private var ink: LeoInk {
        status.textTint.map(LeoInk.tint) ?? .tertiary
    }
}
