import AppKit
import Testing

@testable import Ghostty

/// Esc closes the Tasks popover and is not typed into the terminal.
@MainActor
struct LeoEscapeMonitorTests {
    private static func keyDown(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: keyCode))
    }

    @Test func escapeReachesTheHandler() throws {
        var escapes = 0
        let monitor = LeoEscapeMonitor { escapes += 1 }
        let event = try Self.keyDown(LeoEscapeMonitor.escapeKeyCode)

        NSApp.sendEvent(event)

        #expect(escapes == 1)
        withExtendedLifetime(monitor) {}
    }

    @Test func otherKeysAndChordsPassThrough() throws {
        var escapes = 0
        let monitor = LeoEscapeMonitor { escapes += 1 }

        NSApp.sendEvent(try Self.keyDown(0))
        NSApp.sendEvent(try Self.keyDown(LeoEscapeMonitor.escapeKeyCode, modifiers: .command))

        #expect(escapes == 0)
        withExtendedLifetime(monitor) {}
    }

    @Test func nothingIsHandledOnceTheMonitorIsGone() throws {
        var escapes = 0
        var monitor: LeoEscapeMonitor? = LeoEscapeMonitor { escapes += 1 }
        monitor = nil

        NSApp.sendEvent(try Self.keyDown(LeoEscapeMonitor.escapeKeyCode))

        #expect(escapes == 0)
        #expect(monitor == nil)
    }
}
