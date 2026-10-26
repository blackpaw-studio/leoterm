import Foundation
import LeoKit

/// An agent browser as the app-level registry holds it: what its pane
/// shows, plus running the agent's tool calls and closing. `LeoAgentBrowser`
/// conforms (macOS 14+); tests conform with a fake.
@MainActor protocol LeoAgentBrowserModel: LeoAgentBrowserPaneSource {
    func execute(_ request: LeoClientToolRequest) async -> LeoClientToolOutcome
    /// Opens a blank tab when the browser has none (Open Browser on a row).
    func openBlankTabIfEmpty()
    /// Closes every tab; the agent's data store stays.
    func close()
}

/// Every agent browser in the app, one per (machine, agent) (C5). A browser
/// is made on the agent's first browser request or when the user opens it
/// from the agent's row, and goes when the agent stops or the user closes
/// it. The agent's data store outlives it.
@MainActor final class LeoAgentBrowsers: LeoAgentBrowserPresence, LeoClientToolsExecuting {
    /// Nil when this Mac can't run one (macOS 13).
    typealias MakeBrowser = @MainActor (LeoAgentBrowserKey) -> (any LeoAgentBrowserModel)?

    private let makeBrowser: MakeBrowser
    private let onClosed: @MainActor (LeoAgentBrowserKey) -> Void
    private var browsers: [LeoAgentBrowserKey: any LeoAgentBrowserModel] = [:]
    private var handlers: [UUID: @MainActor (LeoAgentBrowserPresenceChange) -> Void] = [:]

    /// `onClosed` runs after a browser goes (its port forwards are released there).
    init(makeBrowser: @escaping MakeBrowser, onClosed: @escaping @MainActor (LeoAgentBrowserKey) -> Void = { _ in }) {
        self.makeBrowser = makeBrowser
        self.onClosed = onClosed
    }

    // MARK: - LeoAgentBrowserPresence

    var keys: Set<LeoAgentBrowserKey> { Set(browsers.keys) }

    func browser(for key: LeoAgentBrowserKey) -> (any LeoAgentBrowserPaneSource)? { browsers[key] }

    func openBrowser(for key: LeoAgentBrowserKey) -> (any LeoAgentBrowserPaneSource)? {
        guard let browser = browserMaking(key) else { return nil }
        browser.openBlankTabIfEmpty()
        return browser
    }

    func closeBrowser(for key: LeoAgentBrowserKey) {
        guard let browser = browsers.removeValue(forKey: key) else { return }
        browser.close()
        notify(.closed(key))
        onClosed(key)
    }

    func observe(_ handler: @escaping @MainActor (LeoAgentBrowserPresenceChange) -> Void) -> () -> Void {
        let id = UUID()
        handlers[id] = handler
        return { [weak self] in self?.handlers[id] = nil }
    }

    // MARK: - Requests

    func execute(_ request: LeoClientToolRequest, on host: LeoHostID) async -> LeoClientToolOutcome {
        guard let browser = browserMaking(LeoAgentBrowserKey(host: host, agent: request.agent)) else {
            return .failure(LeoBrowserError(.navigationFailed, "This Mac can't run the agent browser (it needs macOS 14)").clientToolError)
        }
        return await browser.execute(request)
    }

    // MARK: - Agents stopping

    /// The agent stopped: its browser closes.
    func agentStopped(_ key: LeoAgentBrowserKey) {
        closeBrowser(for: key)
    }

    /// `host` listed its agents (`statuses` by name) and, when it reports
    /// them, its dispatches' ids: browsers of agents that stopped or are no
    /// longer listed close. Dispatch browsers stay when `dispatches` is nil.
    func agentsListed(on host: LeoHostID, statuses: [String: LeoAgentStatus], dispatches: Set<String>?) {
        let gone = browsers.keys.filter { key in
            guard key.host == host else { return false }
            return !Self.isAlive(key.agent, statuses: statuses, dispatches: dispatches)
        }
        gone.forEach(agentStopped)
    }

    private static let dispatchPrefix = "dispatch:"

    private static func isAlive(_ agent: String, statuses: [String: LeoAgentStatus], dispatches: Set<String>?) -> Bool {
        if agent.hasPrefix(dispatchPrefix) {
            guard let dispatches else { return true }
            return dispatches.contains(String(agent.dropFirst(dispatchPrefix.count)))
        }
        guard let status = statuses[agent] else { return false }
        return status != .stopped
    }

    // MARK: - Helpers

    private func browserMaking(_ key: LeoAgentBrowserKey) -> (any LeoAgentBrowserModel)? {
        if let browser = browsers[key] { return browser }
        guard let browser = makeBrowser(key) else { return nil }
        browsers[key] = browser
        notify(.opened(key))
        return browser
    }

    private func notify(_ change: LeoAgentBrowserPresenceChange) {
        handlers.values.forEach { $0(change) }
    }
}
