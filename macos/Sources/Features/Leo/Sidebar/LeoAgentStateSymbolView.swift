import SwiftUI

/// The agent row's leading symbol, in the state's ink (white on a selected
/// row). A working agent's symbol turns, unless Reduce Motion is on.
struct LeoAgentStateSymbolView: View {
    static let rotationDuration: Double = 1.6

    let state: LeoAgentRowState
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle = 0.0

    var body: some View {
        Image(systemName: state.symbolName)
            .symbolRenderingMode(.hierarchical)
            .font(.body)
            .foregroundStyle(state.symbolInk.style(isSelected: isSelected))
            .rotationEffect(.degrees(angle))
            .task(id: shouldRotate) { setRotating(shouldRotate) }
            .frame(width: LeoAgentRowMetrics.symbolColumnWidth, height: LeoAgentRowMetrics.nameLineHeight)
            .help(state.help ?? "")
            // The name's label already says the state.
            .accessibilityHidden(true)
    }

    private var shouldRotate: Bool { state.rotates && !reduceMotion }

    /// A zero-length animation is what ends a repeating one.
    private func setRotating(_ rotating: Bool) {
        guard rotating || angle != 0 else { return }
        let animation: Animation = rotating
            ? .linear(duration: Self.rotationDuration).repeatForever(autoreverses: false)
            : .linear(duration: 0)
        withAnimation(animation) { angle = rotating ? 360 : 0 }
    }
}
