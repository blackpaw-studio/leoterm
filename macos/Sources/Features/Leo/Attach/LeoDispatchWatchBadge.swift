import SwiftUI

/// B-266: the small indicator on a dispatch's surface. The daemon attaches
/// read-only (`tmux attach -r`), so typing does nothing; this says why.
/// Quiet on purpose: caption text on a material capsule in the corner, no
/// motion, no color (principle 2: only "needs you" earns attention).
struct LeoDispatchWatchBadge: View {
    static let text = "watching · read-only"

    var body: some View {
        Text(Self.text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
            .accessibilityLabel("Watching this dispatch, read-only")
    }
}
