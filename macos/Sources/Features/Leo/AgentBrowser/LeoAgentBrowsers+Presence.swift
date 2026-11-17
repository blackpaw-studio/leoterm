import Foundation
import LeoKit

/// An agent browser as the Mac holds it: what its pane shows, plus running
/// the agent's tool calls and closing. `LeoAgentBrowser` conforms (macOS
/// 14+); tests conform with a fake.
@MainActor protocol LeoAgentBrowserModel: LeoAgentBrowserPaneSource, LeoAgentBrowserRunning {}

/// The LeoKit registry as the Mac's sidebar, pane and handoff notifier see
/// it: every browser it holds is a `LeoAgentBrowserModel`.
extension LeoAgentBrowsers: LeoAgentBrowserPresence {
    func browser(for key: LeoAgentBrowserKey) -> (any LeoAgentBrowserPaneSource)? {
        model(for: key) as? any LeoAgentBrowserPaneSource
    }

    func openBrowser(for key: LeoAgentBrowserKey) -> (any LeoAgentBrowserPaneSource)? {
        openModel(for: key) as? any LeoAgentBrowserPaneSource
    }
}
