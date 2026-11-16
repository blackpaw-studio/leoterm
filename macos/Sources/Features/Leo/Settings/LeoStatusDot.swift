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
        case .connected?: .green
        case .failed?: .red
        case .connecting?: .yellow
        case .disabled?, nil: .gray.opacity(0.5)
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
