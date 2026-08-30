import SwiftUI

/// A small status indicator drawn over a grid cell: a corner dot, plus an
/// optional glowing border for attention states. Pure presentation — driven
/// entirely by the `status` it is handed.
struct CellStatusOverlay: View {
    let status: CellStatus

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let dotSize: CGFloat = 9
    private let dotInset: CGFloat = 6
    /// Matches the cell container's corner radius so the glow border tracks it.
    private let borderCornerRadius: CGFloat = LeoPalette.cellCornerRadius

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
        // Idle renders nothing (no dot, no glow) — don't announce it either,
        // or every plain pty cell narrates "Idle" for no visible reason.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.accessibilityDescription)
        .accessibilityHidden(!(status.isVisible || status.hasGlow))
        .onAppear { startPulseIfNeeded() }
        .onChange(of: status) { _ in startPulseIfNeeded() }
        .onChange(of: reduceMotion) { _ in startPulseIfNeeded() }
    }

    private func startPulseIfNeeded() {
        // Reduce Motion: hold a static (non-animated) attention state instead
        // of a repeating pulse. `isVisible`/`isPulsing` already govern whether
        // the dot/glow render at all; this only removes the animation.
        guard status.isPulsing, !reduceMotion else {
            // Use an explicit finite transaction so SwiftUI cancels any
            // running `repeatForever` animation; a bare assignment leaves the
            // repeating animation active and can produce ghost glow artifacts
            // after a needsYou → idle transition (bell acknowledged).
            withAnimation(.default) { pulse = status.isPulsing && reduceMotion }
            return
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

/// The non-bell inputs needed to derive a cell's status, resolved by the
/// parent from the cell registry + agent roster. The live bell flag is read
/// reactively inside `AgentCellOverlay` (`TerminalGridView.swift`).
struct CellStatusInputs {
    let isAgent: Bool
    let lifecycle: AgentStatus?
    /// Agent display name, for the identity capsule. `nil` for `.pty` cells
    /// or callers that haven't wired name resolution through yet.
    let name: String?
    /// Live activity signal (working/idle/unknown), resolved by the caller
    /// from `LeoActivityStore`. `.unknown` for `.pty` cells, remote-host
    /// boards, or agents the daemon hasn't reported yet.
    let activity: AgentActivity

    /// `name`/`activity` default so existing call sites (e.g. `TerminalView`)
    /// that only pass `isAgent`/`lifecycle` keep compiling unchanged.
    init(isAgent: Bool, lifecycle: AgentStatus?, name: String? = nil, activity: AgentActivity = .unknown) {
        self.isAgent = isAgent
        self.lifecycle = lifecycle
        self.name = name
        self.activity = activity
    }

    static let none = CellStatusInputs(isAgent: false, lifecycle: nil)
}

