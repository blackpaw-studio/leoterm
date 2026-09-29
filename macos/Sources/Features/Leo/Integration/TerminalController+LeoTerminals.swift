import AppKit

/// B-057: a window's terminal rows at its controller's close paths. A row's
/// shell closing (⌘W, `exit`) closes the row -- the window stays, showing
/// the neighbouring row or the start screen -- and a shell kept hidden for
/// a row counts when the window closes.
extension TerminalController {
    /// Whether the window's one surface (`node`, the root) is a terminal
    /// row's shell, whose close closes only the row.
    func leoIsTerminalRow(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> Bool {
        guard case .leaf(let view) = node else { return false }
        return leoSession?.terminals.contains(view.id) == true
    }

    /// Closing the root surface `node`: when it is a terminal row's shell,
    /// the row closes instead of the window, after Ghostty's usual
    /// busy-process confirm (`withConfirmation`). `true` when it took the
    /// close over.
    func leoCloseTerminalRow(_ node: SplitTree<Ghostty.SurfaceView>.Node, withConfirmation: Bool) -> Bool {
        guard leoIsTerminalRow(node), case .leaf(let view) = node, let terminals = leoSession?.terminals else { return false }
        let id = view.id
        let close: () -> Void = { [weak terminals] in terminals?.closeRequested(id) }
        guard withConfirmation else {
            // `exit`: the close request comes from inside libghostty's
            // handling of that very surface, which mustn't be freed under it.
            DispatchQueue.main.async { close() }
            return true
        }
        confirmClose(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
        ) { close() }
        return true
    }

    /// Whether closing this window would kill a running process: one it
    /// shows, or one in a shell it keeps hidden for a terminal row.
    var leoNeedsConfirmClose: Bool {
        surfaceTree.contains(where: { $0.needsConfirmQuit }) || leoSession?.terminals.hasBusyHiddenShell() == true
    }
}
