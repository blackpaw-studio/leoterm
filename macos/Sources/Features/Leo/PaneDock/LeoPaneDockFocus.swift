import AppKit

/// A view controller that is a dockable pane, or a strip holding one (B-439).
@MainActor protocol LeoDockPaneOwning: AnyObject {
    /// The pane it stands for now; nil when it holds none.
    var leoDockPane: LeoDockPane? { get }
}

/// Which pane holds keyboard focus (B-439), for View ▸ Dock Focused Pane.
enum LeoPaneDockFocus {
    /// The pane up `responder`'s responder chain -- a view's controller
    /// follows the view, so the nearest owner wins: the browser's pane
    /// inside a strip that also holds Files is the browser. A field's editor
    /// stands for its field. Nil in the terminal, chat or sidebar.
    @MainActor static func pane(for responder: NSResponder?) -> LeoDockPane? {
        var current = responder
        if let editor = current as? NSText, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
            current = field
        }
        while let next = current {
            if let pane = (next as? LeoDockPaneOwning)?.leoDockPane { return pane }
            current = next.nextResponder
        }
        return nil
    }
}

extension LeoAgentBrowserPaneViewController: LeoDockPaneOwning {
    var leoDockPane: LeoDockPane? { .browser }
}

extension LeoWorkspaceBrowserViewController: LeoDockPaneOwning {
    var leoDockPane: LeoDockPane? { .files }
}

extension LeoEditorTabsViewController: LeoDockPaneOwning {
    /// Files', unless the strip holds the Browser alone.
    var leoDockPane: LeoDockPane? {
        let hosts = hostedPanes
        return hosts.contains(.files) ? .files : hosts.contains(.browser) ? .browser : nil
    }
}
