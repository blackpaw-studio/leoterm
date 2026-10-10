import AppKit

/// Menu bar actions for the window's workspace browser (B-005): Agents ▸
/// Browse Agent Files (⌥⌘B), Show Hidden Files (⇧⌘.) and Reload Files
/// (⌘R, while the browser has focus). ⌘W closes the browser only while
/// it has focus (see `LeoWorkspaceBrowserViewController.close(_:)`).
extension TerminalController {
    /// Agents ▸ Browse Agent Files: the focused agent's workspace, else the
    /// sidebar selection's. Toggles: open, then focus, then close.
    @IBAction func browseLeoAgentFiles(_ sender: Any?) {
        guard let runtime = leoRuntime else { return }
        let agent = runtime.editorContext(in: self)
        guard agent.name != nil, let browser = leoSession?.browser else { return NSSound.beep() }
        switch browser.browseStep(for: agent, hasFocus: leoSession?.browserPane?.hasFocus == true) {
        case .open: browseLeoFiles(for: agent)
        case .focus: leoSession?.browserPane?.focusList()
        case .close: closeLeoBrowser()
        }
    }

    /// The sidebar row's Browse Files (B-274): roots that row's own browser
    /// at its workspace, shows the row, and focuses the browser.
    func browseLeoFiles(forRow row: LeoAgentRow) {
        guard let leoSession, let runtime = leoRuntime else { return }
        let agent = LeoEditorAgentContext(host: row.host, name: row.name, workspace: row.workspace)
        let pane = runtime.pane(for: row, in: leoSession)
        Task {
            await pane.browser.open(agent)
            await runtime.showRow(row, in: leoSession)
            guard leoSession.panes.active === pane else { return }
            leoSession.browserPane?.sync()
            leoSession.browserPane?.focusList()
        }
    }

    /// Browse Agent Files: roots the browser on screen at `agent`'s
    /// workspace and focuses it.
    func browseLeoFiles(for agent: LeoEditorAgentContext) {
        guard let leoSession else { return }
        Task {
            await leoSession.browser.open(agent)
            leoSession.browserPane?.sync()
            leoSession.browserPane?.focusList()
        }
    }

    /// Agents ▸ Show Hidden Files (⇧⌘.), like Finder's.
    @IBAction func toggleLeoHiddenFiles(_ sender: Any?) {
        guard let browser = leoSession?.browser else { return }
        Task { await browser.toggleHiddenFiles() }
    }

    /// Agents ▸ Reload Files (⌘R while the browser has focus).
    @IBAction func reloadLeoAgentFiles(_ sender: Any?) {
        guard let browser = leoSession?.browser else { return }
        Task { await browser.reload() }
    }

    /// Returns nil for items that aren't the browser's.
    func validateLeoBrowserMenuItem(_ item: NSMenuItem) -> Bool? {
        let browser = leoSession?.browser
        switch item.action {
        case #selector(browseLeoAgentFiles(_:)):
            guard let runtime = leoRuntime, let browser else { return false }
            let agent = runtime.editorContext(in: self)
            let isClosing = browser.browseStep(for: agent, hasFocus: leoSession?.browserPane?.hasFocus == true) == .close
            item.title = isClosing ? "Close Agent Files" : "Browse Agent Files"
            return agent.name != nil
        case #selector(toggleLeoHiddenFiles(_:)):
            item.state = browser?.showsHiddenFiles == true ? .on : .off
            return browser?.isOpen == true
        case #selector(reloadLeoAgentFiles(_:)):
            return browser?.isOpen == true && leoSession?.browserPane?.hasFocus == true
        default:
            return nil
        }
    }

    private func closeLeoBrowser() {
        guard let leoSession else { return }
        let surface = focusedSurface
        Task {
            await leoSession.browser.close()
            if let surface { Ghostty.moveFocus(to: surface) }
        }
    }
}
