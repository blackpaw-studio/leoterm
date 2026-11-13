/// What the toolbar's three tool toggles (Files, Browser, Agent Pane) show,
/// folded from the panels' own state, and what a click on each does. Pure:
/// `TerminalController+Leo` builds one on every change and pushes it to the
/// toolbar; the menu bar's Show/Hide titles read the same value.
///
/// With no agent shown (a plain terminal, the start screen) every toggle is
/// disabled, the rule Interrupt follows. A toggle the setting removes (the
/// Browser, with Agent browser off) is not present rather than disabled.
struct LeoToolbarToolState: Equatable {
    struct Tool: Equatable {
        let isPresent: Bool
        let isEnabled: Bool
        let isOn: Bool
    }

    /// What clicking the Files toggle does: it flips between open and
    /// closed (⌥⌘B keeps its extra focus step).
    enum FilesStep: Equatable { case open, close }

    /// What clicking the Browser toggle does. Turning it off with editor
    /// tabs open shows the editor, so the browser stays open behind it;
    /// without tabs it closes the browser, as the browser's own Close does.
    enum BrowserStep: Equatable { case open, showEditor, close }

    let files: Tool
    let browser: Tool
    let agentPane: Tool
    let filesStep: FilesStep
    let browserStep: BrowserStep

    /// No agent shown, and every panel closed.
    static let none = LeoToolbarToolState(
        hasAgent: false, browserSettingOn: true, filesOpen: false, browserFront: false, editorHasTabs: false, paneShown: false,
        paneExpanded: false)

    init(
        hasAgent: Bool, browserSettingOn: Bool, filesOpen: Bool, browserFront: Bool, editorHasTabs: Bool, paneShown: Bool,
        paneExpanded: Bool
    ) {
        files = Tool(isPresent: true, isEnabled: hasAgent, isOn: hasAgent && filesOpen)
        browser = Tool(isPresent: browserSettingOn, isEnabled: hasAgent, isOn: hasAgent && browserFront)
        agentPane = Tool(isPresent: true, isEnabled: hasAgent, isOn: hasAgent && paneShown && paneExpanded)
        filesStep = filesOpen ? .close : .open
        browserStep = !browserFront ? .open : (editorHasTabs ? .showEditor : .close)
    }

    var filesMenuTitle: String { files.isOn ? "Hide Files" : "Show Files" }
    var browserMenuTitle: String { browser.isOn ? "Hide Agent Browser" : "Show Agent Browser" }
    var agentPaneMenuTitle: String { agentPane.isOn ? "Hide Agent Pane" : "Show Agent Pane" }
}
