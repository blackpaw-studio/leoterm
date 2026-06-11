import SwiftUI

/// Placeholder rendered in a board slot whose agent is no longer running.
/// Keeps the slot/size and offers respawn or removal.
struct DeadCellView: View {
    let snapshot: AgentSnapshot
    let onRespawn: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
            Text(snapshot.name)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(snapshot.repo)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Agent stopped")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                Button("Respawn", action: onRespawn)
                Button("Remove", role: .destructive, action: onRemove)
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }
}
