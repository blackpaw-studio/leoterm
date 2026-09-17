import AppKit
import Testing

@testable import Ghostty

/// Pure `Selector -> LeoAgentPaletteFieldCommand` mapping used by
/// `LeoAgentPaletteSearchField.Coordinator.control(_:textView:doCommandBy:)`
/// to intercept ↑/↓/Return/Esc before the field editor consumes them.
struct LeoAgentPaletteFieldCommandTests {
    @Test func moveUpMapsToMoveUp() {
        #expect(LeoAgentPaletteFieldCommand.action(for: #selector(NSResponder.moveUp(_:))) == .moveUp)
    }

    @Test func moveDownMapsToMoveDown() {
        #expect(LeoAgentPaletteFieldCommand.action(for: #selector(NSResponder.moveDown(_:))) == .moveDown)
    }

    @Test func insertNewlineMapsToSubmit() {
        #expect(LeoAgentPaletteFieldCommand.action(for: #selector(NSResponder.insertNewline(_:))) == .submit)
    }

    @Test func cancelOperationMapsToCancel() {
        #expect(LeoAgentPaletteFieldCommand.action(for: #selector(NSResponder.cancelOperation(_:))) == .cancel)
    }

    @Test func unrelatedSelectorMapsToNil() {
        #expect(LeoAgentPaletteFieldCommand.action(for: #selector(NSResponder.deleteBackward(_:))) == nil)
    }
}
