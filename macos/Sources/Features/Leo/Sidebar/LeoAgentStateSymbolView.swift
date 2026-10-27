import AppKit
import SwiftUI

/// The agent row's leading symbol, in the state's ink (white on a selected
/// row). A working agent's symbol turns, unless Reduce Motion is on.
struct LeoAgentStateSymbolView: View {
    static let rotationDuration: Double = 1.6

    let state: LeoAgentRowState
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        symbol
            .frame(width: LeoAgentRowMetrics.symbolColumnWidth, height: LeoAgentRowMetrics.nameLineHeight)
            .help(state.help ?? "")
            // The name's label already says the state.
            .accessibilityHidden(true)
    }

    /// Turned by Core Animation (see `LeoSpinningSymbolView`), never by a
    /// repeating SwiftUI animation.
    @ViewBuilder private var symbol: some View {
        let ink = state.symbolInk.forSymbol(isSelected: isSelected)
        if shouldRotate, let color = Self.spinColor(ink, isSelected: isSelected) {
            LeoSpinningSymbolView(symbolName: state.symbolName, color: color, period: Self.rotationDuration)
        } else {
            Image(systemName: state.symbolName)
                .symbolRenderingMode(.hierarchical)
                .font(.body)
                .foregroundStyle(ink.style(isSelected: isSelected))
        }
    }

    private var shouldRotate: Bool { state.rotates && !reduceMotion }

    /// The turning symbol's colour: only a tint or white turns (a working
    /// agent's blue); a grey falls back to the still symbol.
    private static func spinColor(_ ink: LeoInk, isSelected: Bool) -> NSColor? {
        switch ink {
        case .white: .white
        case .tint(let tint): isSelected ? .white : tint.nsColor
        case .secondary, .tertiary: nil
        }
    }
}
