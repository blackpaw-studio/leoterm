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

    /// A tool call running on a browser: answered by its run, or by the
    /// browser closing first.
    private struct Call {
        let run: Task<LeoClientToolOutcome, Never>
        let answer: CheckedContinuation<LeoClientToolOutcome, Never>
    }

    private static let closedError = LeoClientToolError(code: "cancelled", message: "The agent's browser was closed")

    private let makeBrowser: MakeBrowser
    private let onClosed: @MainActor (LeoAgentBrowserKey) -> Void
    private var browsers: [LeoAgentBrowserKey: any LeoAgentBrowserModel] = [:]
    private var calls: [LeoAgentBrowserKey: [UUID: Call]] = [:]
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

    /// Every call still running on the browser is stopped and answered
    /// `cancelled` -- a pending handoff included -- so no agent is left waiting.
    func closeBrowser(for key: LeoAgentBrowserKey) {
        guard let browser = browsers.removeValue(forKey: key) else { return }
        calls.removeValue(forKey: key)?.values.forEach { call in
            call.run.cancel()
            call.answer.resume(returning: .failure(Self.closedError))
        }
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
        let key = LeoAgentBrowserKey(host: host, agent: request.agent)
        guard let browser = browserMaking(key) else {
            return .failure(LeoBrowserError(.navigationFailed, "This Mac can't run the agent browser (it needs macOS 14)").clientToolError)
        }
        let id = UUID()
        let run = Task { await browser.execute(request) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { answer in
                calls[key, default: [:]][id] = Call(run: run, answer: answer)
                Task { self.answer(id, on: key, with: await run.value) }
            }
        } onCancel: {
            run.cancel()
        }
    }

    /// A no-op once the browser closed: its close already answered.
    private func answer(_ id: UUID, on key: LeoAgentBrowserKey, with outcome: LeoClientToolOutcome) {
        guard let call = calls[key]?.removeValue(forKey: id) else { return }
        if calls[key]?.isEmpty == true { calls[key] = nil }
        call.answer.resume(returning: outcome)
    }

    // MARK: - Agents stopping

    /// `host` was removed from Settings: every browser on it closes.
    func machineRemoved(_ host: LeoHostID) {
        browsers.keys.filter { $0.host == host }.forEach(closeBrowser)
    }

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
