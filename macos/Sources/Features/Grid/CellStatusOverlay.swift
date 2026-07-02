import SwiftUI

/// A small status indicator drawn over a grid cell: a corner dot, plus an
/// optional glowing border for attention states. Pure presentation — driven
/// entirely by the `status` it is handed.
struct CellStatusOverlay: View {
    let status: CellStatus

    @State private var pulse = false

    private let dotSize: CGFloat = 9
    private let dotInset: CGFloat = 6
    /// Matches the cell container's corner radius so the glow border tracks it.
    private let borderCornerRadius: CGFloat = 6

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Glow border for attention states.
            if status.hasGlow {
                RoundedRectangle(cornerRadius: borderCornerRadius)
                    .stroke(status.color, lineWidth: 2)
                    .shadow(color: status.color.opacity(0.8), radius: pulse ? 6 : 2)
                    .opacity(pulse ? 1.0 : 0.55)
                    .allowsHitTesting(false)
            }

            // Corner status dot — absent for idle (absence signals "nothing happening").
            if status.isVisible {
                Circle()
                    .fill(status.color)
                    .frame(width: dotSize, height: dotSize)
                    .opacity(status.isPulsing ? (pulse ? 1.0 : 0.4) : 0.9)
                    .padding(dotInset)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { startPulseIfNeeded() }
        .onChange(of: status) { _ in startPulseIfNeeded() }
    }

    private func startPulseIfNeeded() {
        guard status.isPulsing else {
            // Use an explicit finite transaction so SwiftUI cancels any
            // running `repeatForever` animation; a bare assignment leaves the
            // repeating animation active and can produce ghost glow artifacts
            // after a needsYou → idle transition (bell acknowledged).
            withAnimation(.default) { pulse = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

/// The non-bell inputs needed to derive a cell's status, resolved by the
/// parent from the cell registry + agent roster. The live bell flag is read
/// reactively inside `CellStatusBadge`.
struct CellStatusInputs {
    let isAgent: Bool
    let lifecycle: AgentStatus?

    static let none = CellStatusInputs(isAgent: false, lifecycle: nil)
}

/// Observes a surface's `bell` flag and renders the status overlay. The
/// `@ObservedObject` on `surface` is what makes the dot/border update live
/// when a bell rings or clears (on focus/keydown). Lifecycle changes
/// re-render the grid via dead-cell reconciliation, so they need no observer.
struct CellStatusBadge: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    let inputs: CellStatusInputs

    var body: some View {
        CellStatusOverlay(
            status: deriveCellStatus(
                isAgent: inputs.isAgent,
                hasBell: surface.bell,
                lifecycle: inputs.lifecycle
            )
        )
    }
}
