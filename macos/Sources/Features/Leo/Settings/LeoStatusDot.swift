import LeoKit
import SwiftUI

/// A machine's connection state as a dot, with a spoken label.
struct LeoStatusDot: View {
    let status: LeoMachineStatus?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch status {
        case .connected?: LeoTint.green.color
        case .failed?: LeoTint.red.color
        case .connecting?: LeoTint.orange.color
        case .disabled?, nil: Color(nsColor: .tertiaryLabelColor)
        }
    }

    private var label: String {
        switch status {
        case .connected?: "Connected"
        case .failed?: "Unreachable"
        case .connecting?: "Connecting"
        case .disabled?: "Disabled"
        case nil: "Not connected"
        }
    }
}
