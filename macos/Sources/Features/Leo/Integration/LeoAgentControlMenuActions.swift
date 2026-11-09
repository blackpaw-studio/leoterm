import AppKit

/// Agents ▸ Message Agent / Interrupt / Compact Context / Clear
/// Conversation… (B-262): the keyboard path to the agent verbs, on the
/// sidebar's selected agent and validated through the same
/// `LeoAgentControlAvailability` the toolbar's Interrupt and "⋯" read.
/// Message Agent opens Chat on its composer.
extension TerminalController {
    @IBAction func messageSelectedLeoAgent(_ sender: Any?) {
        leoSession.map { LeoViewMenuActions.messageAgent(in: $0) }
    }

    @IBAction func interruptSelectedLeoAgent(_ sender: Any?) {
        // The toolbar's item can be stale for a turn after a disconnect: the
        // action re-checks the rule the menu item and the item both read.
        guard validateLeoControlMenuItem(\.canInterrupt), let control = leoRuntime?.control, let row = selectedLeoRow else { return }
        Task { await control.interrupt(row) }
    }

    @IBAction func compactSelectedLeoAgent(_ sender: Any?) {
        guard let control = leoRuntime?.control, let row = selectedLeoRow else { return }
        Task { await control.compact(row) }
    }

    @IBAction func clearSelectedLeoAgent(_ sender: Any?) {
        guard let control = leoRuntime?.control, let row = selectedLeoRow else { return }
        Task { await control.clear(row, in: window) }
    }

    func validateLeoMessageMenuItem() -> Bool {
        leoSession.map { LeoViewMenuActions.canMessage(in: $0) } ?? false
    }

    func validateLeoControlMenuItem(_ allowed: KeyPath<LeoAgentControlAvailability, Bool>) -> Bool {
        guard leoSession != nil, let runtime = leoRuntime else { return false }
        return runtime.controlAvailability(for: selectedLeoRow)[keyPath: allowed]
    }
}
