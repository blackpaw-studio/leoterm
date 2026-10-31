import Foundation
import LeoFeatures
import SwiftTerm

/// A headless emulator behind the chat's terminal strip: sized like the full
/// terminal (the strip's attach is read-only and never resizes the agent's
/// window), it only reads back the bottom rows of what the agent drew.
@MainActor
final class StripEmulator {
    private let delegate = Delegate()
    private let terminal: SwiftTerm.Terminal
    private var size: TerminalSize?

    init() {
        terminal = SwiftTerm.Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 24, scrollback: 0))
    }

    func feed(_ data: Data) {
        terminal.feed(buffer: ArraySlice(data))
    }

    /// A new attach opened: tmux redraws everything.
    func reset(to size: TerminalSize) {
        terminal.resetToInitialState()
        resize(to: size)
    }

    func resize(to size: TerminalSize) {
        guard size != self.size else { return }
        self.size = size
        terminal.resize(cols: size.cols, rows: size.rows)
    }

    /// The strip's rows: the agent's latest output, without its chrome.
    func lines(count: Int = TerminalStripLines.count) -> [String] {
        let rows = (0..<terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
        return TerminalStripLines.rows(rows, count: count)
    }

    /// Nothing leaves a read-only strip: no input, and no replies.
    private final class Delegate: TerminalDelegate {
        func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {}
    }
}
