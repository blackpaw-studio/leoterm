import AppKit
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-287: Return on the sidebar opens its selected row (B-049), and only
/// Return does. ⌃C, ⌃M and ⌃J type the same characters as Enter, Return
/// and newline, and they belong to the terminal (P1): the sidebar must not
/// claim them in the window's key-equivalent pass.
///
/// Drives a real `LeoSidebarView` in a window (key status not required) through its own
/// `performKeyEquivalent(with:)`, where AppKit offers it a key before the
/// first responder's `keyDown`.
@MainActor @Suite(.serialized)
struct LeoSidebarReturnKeyTests {
    enum Selected: CaseIterable, Sendable { case terminal, agent }

    struct Key: Sendable, CustomTestStringConvertible {
        let name: String
        let characters: String
        let charactersIgnoringModifiers: String
        let keyCode: UInt16
        let modifierFlags: NSEvent.ModifierFlags

        var testDescription: String { name }

        static let controlC = Key(name: "⌃C", characters: "\u{3}", charactersIgnoringModifiers: "c", keyCode: 8, modifierFlags: .control)
        static let controlM = Key(name: "⌃M", characters: "\r", charactersIgnoringModifiers: "m", keyCode: 46, modifierFlags: .control)
        static let controlJ = Key(name: "⌃J", characters: "\n", charactersIgnoringModifiers: "j", keyCode: 38, modifierFlags: .control)
        static let `return` = Key(name: "Return", characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 36, modifierFlags: [])
        static let keypadEnter = Key(
            name: "Enter", characters: "\u{3}", charactersIgnoringModifiers: "\u{3}", keyCode: 76, modifierFlags: [.numericPad, .function])
        static let shiftReturn = Key(name: "⇧Return", characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 36, modifierFlags: .shift)
        static let optionReturn = Key(name: "⌥Return", characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 36, modifierFlags: .option)
        static let commandReturn = Key(name: "⌘Return", characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 36, modifierFlags: .command)
    }

    @Test(arguments: Selected.allCases, [Key.controlC, .controlM, .controlJ])
    func controlKeysDoNotActivateTheSelection(_ selected: Selected, _ key: Key) async throws {
        let harness = try await ReturnKeyHarness(selecting: selected)
        defer { harness.close() }

        let claimed = try harness.press(key)

        #expect(!claimed, "the sidebar claimed \(key.name)")
        #expect(harness.activations.isEmpty, "\(key.name) opened the selected row")
    }

    /// B-049: Return and keypad Enter open the selected row, once.
    @Test(arguments: [Key.return, .keypadEnter])
    func returnActivatesTheSelection(_ key: Key) async throws {
        let harness = try await ReturnKeyHarness(selecting: .terminal)
        defer { harness.close() }

        let claimed = try harness.press(key)

        #expect(claimed, "the sidebar let \(key.name) through")
        #expect(harness.activations == ["show terminal"])
    }

    /// Modified Returns aren't the sidebar's, and with no row selected
    /// there is nothing for Return to open.
    @Test(arguments: [(Key.shiftReturn, Selected?.some(.terminal)), (.optionReturn, .terminal), (.commandReturn, .terminal), (.return, nil)])
    func returnDoesNothingWhenModifiedOrUnselected(_ key: Key, _ selected: Selected?) async throws {
        let harness = try await ReturnKeyHarness(selecting: selected)
        defer { harness.close() }

        let claimed = try harness.press(key)

        #expect(!claimed, "the sidebar claimed \(key.name)")
        #expect(harness.activations.isEmpty, "\(key.name) opened a row")
    }

    /// B-297: Return reaches the sidebar through the key-equivalent pass, which
    /// needs no key status; a window that can't become key (screen locked,
    /// another app in front) still activates the selection.
    @Test func returnActivatesTheSelectionInAWindowThatCannotBecomeKey() async throws {
        let harness = try await ReturnKeyHarness(selecting: .terminal, window: NeverKeyWindow.make())
        defer { harness.close() }

        let claimed = try harness.press(.return)

        #expect(!harness.window.canBecomeKey)
        #expect(claimed, "the sidebar let Return through")
        #expect(harness.activations == ["show terminal"])
    }
}

/// A window the window server never gives key status, as on a locked screen.
private final class NeverKeyWindow: NSWindow {
    override var canBecomeKey: Bool { false }

    static func make() -> NSWindow {
        let window = NeverKeyWindow(
            contentRect: NSRect(x: 120, y: 120, width: 320, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}

// MARK: - Harness

@MainActor private final class ReturnKeyHarness {
    let window: NSWindow
    private(set) var activations: [String] = []

    private static let worker = LeoAgentRow(
        host: .local, name: "worker", template: nil, status: .running, activity: .idle, actionDetail: nil
    )
    private static let timeout: Duration = .seconds(5)

    init(selecting selected: LeoSidebarReturnKeyTests.Selected?, window: NSWindow? = nil) async throws {
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: [Self.worker], connectivity: .connected, generation: 1))
        let terminals = LeoWindowTerminals()
        let terminal = UUID()
        terminals.add(terminal, title: "zsh")
        switch selected {
        case .terminal: terminals.select(terminal)
        case .agent: model.userSelected(Self.worker.id)
        case nil: break
        }
        let actions = LeoAgentActions(
            clients: FakeMachineClients(daemon: ReturnKeyDaemon()), cli: .recordingForTests(), model: model,
            processRunner: LeoRecordingTemplateRunner(), refresh: {})
        let window = window ?? Self.makeWindow()
        self.window = window
        window.contentView = NSHostingView(rootView: LeoSidebarView(model: model, windowID: LeoWindowID(), actions: actions, terminals: terminals))

        terminals.showRequested = { [weak self] _ in self?.activations.append("show terminal") }
        model.attachRequested = { [weak self] row, _, _ in self?.activations.append("attach \(row.name)") }
        model.focusExistingRequested = { [weak self] row, _ in self?.activations.append("focus \(row.name)") }

        // The window's key-equivalent pass doesn't need key status, and
        // another app holding the foreground would keep this one from
        // ever getting it; the window only has to be on screen and laid
        // out for the sidebar's Return view to exist.
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let hasReturnKeyView = await Self.eventually { [window] in
            window.contentView?.layoutSubtreeIfNeeded()
            return window.contentView.map(Self.containsReturnKeyView) ?? false
        }
        try #require(hasReturnKeyView, "the sidebar's Return key view never joined the window")
    }

    static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 320, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func containsReturnKeyView(_ view: NSView) -> Bool {
        view is LeoSidebarReturnKeyView || view.subviews.contains(where: containsReturnKeyView)
    }

    /// Offers `key` to the window's key equivalents, as AppKit does before
    /// `keyDown`; whether anything in the window claimed it.
    func press(_ key: LeoSidebarReturnKeyTests.Key) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: key.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: key.characters, charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            isARepeat: false, keyCode: key.keyCode
        ))
        return window.performKeyEquivalent(with: event)
    }

    func close() { window.close() }

    private static func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private struct ReturnKeyDaemon: LeoDaemonClient {
    func listAgents() async throws -> [LeoAgent] { [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func start(_ name: String) async throws { throw LeoDaemonError.transport("unused") }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { throw LeoDaemonError.transport("unused") }
    func restart(_ name: String) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func reset(_ name: String) async throws { throw LeoDaemonError.transport("unused") }
    func setTemplate(_ name: String, template: String) async throws { throw LeoDaemonError.transport("unused") }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { throw LeoDaemonError.transport("unused") }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { throw LeoDaemonError.transport("unused") }
    func logs(_ name: String, lines: Int?) async throws -> String { throw LeoDaemonError.transport("unused") }
}
