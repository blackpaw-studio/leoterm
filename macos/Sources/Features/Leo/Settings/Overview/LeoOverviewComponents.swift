import LeoKit
import SwiftUI

/// The connection state as a capsule badge, in semantic system colours.
struct LeoConnectionBadge: View {
    let status: LeoMachineStatus?

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(title).font(.callout)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(tint.opacity(0.15), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch status {
        case .connected?: LeoTint.green.color
        case .failed?: LeoTint.red.color
        case .connecting?: LeoTint.orange.color
        case .disabled?, nil: Color(nsColor: .secondaryLabelColor)
        }
    }

    private var title: String {
        switch status {
        case .connected?: "Connected"
        case .failed?: "Unreachable"
        case .connecting?: "Connecting"
        case .disabled?: "Off"
        case nil: "Not connected"
        }
    }
}

/// An overview's header: a symbol, the machine's name and a subtitle, with the
/// connection badge (or another trailing control) at the end.
struct LeoOverviewHeader<Trailing: View>: View {
    let systemImage: String
    let name: String
    let subtitle: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(LeoTint.blue.color, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.title3.weight(.semibold))
                if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
    }
}

/// A line explaining why a machine can't be used ("Off", the connection error).
struct LeoOverviewReason: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(LeoTint.orange.color)
            .textSelection(.enabled)
    }
}
