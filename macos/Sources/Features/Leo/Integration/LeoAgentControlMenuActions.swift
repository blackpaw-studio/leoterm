import AppKit

/// Agents ▸ Message Agent / Interrupt / Compact Context / Clear
/// Conversation… (B-262): the keyboard path to the control bar's verbs, on
/// the sidebar's selected agent and validated through the same
/// `LeoAgentControlAvailability` the bar reads.
extension TerminalController {
    @IBAction func messageSelectedLeoAgent(_ sender: Any?) {
        leoSession?.requestControlFocus()
    }

    @IBAction func interruptSelectedLeoAgent(_ sender: Any?) {
        guard let control = leoRuntime?.control, let row = selectedLeoRow else { return }
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

    func validateLeoControlMenuItem(_ allowed: KeyPath<LeoAgentControlAvailability, Bool>) -> Bool {
        guard leoSession != nil, let runtime = leoRuntime else { return false }
        return runtime.controlAvailability(for: selectedLeoRow)[keyPath: allowed]
    }
}
