import AppKit

/// The tool toggles' actions and state: Files, the agent's Browser and the
/// Agent Pane, from the toolbar and from View ▸ Show/Hide Files, Show/Hide
/// Agent Browser and Show/Hide Agent Pane. Every toolbar toggle is also a
/// menu item (HIG), and both read the same `LeoToolbarToolState`.
extension TerminalController {
    /// The shown agent's panels, folded for the toggles and the menu titles.
    /// "Shown" is the row whose pane is on screen: an agent row, not a
    /// terminal row or the start screen.
    var leoToolState: LeoToolbarToolState {
        guard let leoSession, let leoRuntime else { return .none }
        let panes = leoSession.panes
        let pane = panes.active
        var hasAgent = false
        if case .agent = panes.activeKey { hasAgent = true }
        return LeoToolbarToolState(
            hasAgent: hasAgent, browserSettingOn: leoRuntime.agentBrowsers.setting.isEnabled, filesOpen: pane.browser.isOpen,
            browserFront: pane.content == .agentBrowser, editorHasTabs: !pane.tabs.tabs.isEmpty,
            paneShown: leoSession.agentPane?.isShown ?? false, paneExpanded: leoSession.agentPane?.isExpanded ?? false)
    }

    /// The Files toolbar toggle: open or closed, nothing else. ⌥⌘B
    /// (`browseLeoAgentFiles`) keeps its extra focus step.
    @IBAction func toggleLeoFilesPanel(_ sender: Any?) {
        guard let runtime = leoRuntime else { return }
        let agent = runtime.editorContext(in: self)
        guard agent.name != nil, leoToolState.files.isEnabled else { return NSSound.beep() }
        switch leoToolState.filesStep {
        case .open: browseLeoFiles(for: agent)
        case .close: closeLeoBrowser()
        }
    }

    /// View ▸ Show/Hide Agent Browser and the Browser toggle. Hiding keeps
    /// the browser open behind the editor when files are open; otherwise it
    /// closes, as the browser's own Close does.
    @IBAction func toggleLeoAgentBrowser(_ sender: Any?) {
        guard let panes = leoSession?.panes, leoToolState.browser.isEnabled else { return NSSound.beep() }
        switch leoToolState.browserStep {
        case .open: if !panes.openAgentBrowser(for: panes.activeKey) { NSSound.beep() }
        case .showEditor: panes.active.showEditor()
        case .close: panes.active.closeAgentBrowser()
        }
    }

    /// Returns nil for items that aren't the tool toggles'.
    func validateLeoToolMenuItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(toggleLeoAgentBrowser(_:)):
            let state = leoToolState
            item.title = state.browserMenuTitle
            item.isHidden = !state.browser.isPresent
            return state.browser.isEnabled
        default:
            return nil
        }
    }
}
