import Foundation

/// Names one agent's browser: the machine it runs on and the agent's name as
/// the daemon knows it. A dispatch child is named `dispatch:<id>` (its
/// `LEO_PROCESS_NAME`), so each dispatch has its own browser.
public struct LeoAgentBrowserKey: Hashable, Sendable {
    public let host: LeoHostID
    public let agent: String

    public init(host: LeoHostID, agent: String) {
        self.host = host
        self.agent = agent
    }

    public static func dispatch(host: LeoHostID, id: String) -> Self {
        Self(host: host, agent: "dispatch:\(id)")
    }
}

public enum LeoAgentBrowserPresenceChange: Equatable, Sendable {
    case opened(LeoAgentBrowserKey)
    case closed(LeoAgentBrowserKey)
}

/// An agent browser as the registry holds it: running the agent's tool
/// calls and closing. Each app's browser model conforms (the Mac's
/// WebKit-backed `LeoAgentBrowser`, iOS's `LeoIOSAgentBrowser`); tests
/// conform with a fake.
@MainActor public protocol LeoAgentBrowserRunning: AnyObject {
    /// Who drives: the pane's pill, handoff banner and user input report here.
    var control: LeoBrowserControlModel { get }
    func execute(_ request: LeoClientToolRequest) async -> LeoClientToolOutcome
    /// Opens a blank tab when the browser has none (Open Browser).
    func openBlankTabIfEmpty()
    /// Closes every tab; the agent's data store stays.
    func close()
}

/// Every agent browser in the app, one per (machine, agent) (C5). A browser
/// is made on the agent's first browser request or when the user opens it,
/// and goes when the agent stops or the user closes it. The agent's data
/// store outlives it. Both apps run their claimed `browser` requests here.
@MainActor public final class LeoAgentBrowsers: LeoClientToolsExecuting {
    /// Nil when this device can't run one.
    public typealias MakeBrowser = @MainActor (LeoAgentBrowserKey) -> (any LeoAgentBrowserRunning)?

    /// A tool call running on a browser: answered by its run, or by the
    /// browser closing first.
    private struct Call {
        let run: Task<LeoClientToolOutcome, Never>
        let answer: CheckedContinuation<LeoClientToolOutcome, Never>
    }

    private static let closedError = LeoClientToolError(code: "cancelled", message: "The agent's browser was closed")

    private let makeBrowser: MakeBrowser
    private let unavailable: LeoBrowserError
    private let onClosed: @MainActor (LeoAgentBrowserKey) -> Void
    private var browsers: [LeoAgentBrowserKey: any LeoAgentBrowserRunning] = [:]
    private var calls: [LeoAgentBrowserKey: [UUID: Call]] = [:]
    private var handlers: [UUID: @MainActor (LeoAgentBrowserPresenceChange) -> Void] = [:]

    /// `unavailable` answers a request `makeBrowser` can't serve. `onClosed`
    /// runs after a browser goes (the Mac releases its port forwards there).
    public init(
        makeBrowser: @escaping MakeBrowser,
        unavailable: LeoBrowserError = LeoBrowserError(.navigationFailed, "This device can't run the agent browser"),
        onClosed: @escaping @MainActor (LeoAgentBrowserKey) -> Void = { _ in }
    ) {
        self.makeBrowser = makeBrowser
        self.unavailable = unavailable
        self.onClosed = onClosed
    }

    // MARK: - Presence

    public var keys: Set<LeoAgentBrowserKey> { Set(browsers.keys) }

    /// The agent's browser, if it has one.
    public func model(for key: LeoAgentBrowserKey) -> (any LeoAgentBrowserRunning)? { browsers[key] }

    /// The agent's browser, made if needed, with a blank tab when it has
    /// none; nil when this device can't run one.
    public func openModel(for key: LeoAgentBrowserKey) -> (any LeoAgentBrowserRunning)? {
        guard let browser = browserMaking(key) else { return nil }
        browser.openBlankTabIfEmpty()
        return browser
    }

    /// Every call still running on the browser is stopped and answered
    /// `cancelled` -- a pending handoff included -- so no agent is left waiting.
    public func closeBrowser(for key: LeoAgentBrowserKey) {
        guard let browser = browsers.removeValue(forKey: key) else { return }
        calls.removeValue(forKey: key)?.values.forEach { call in
            call.run.cancel()
            call.answer.resume(returning: .failure(Self.closedError))
        }
        browser.close()
        notify(.closed(key))
        onClosed(key)
    }

    public func observe(_ handler: @escaping @MainActor @Sendable (LeoAgentBrowserPresenceChange) -> Void) -> () -> Void {
        let id = UUID()
        handlers[id] = handler
        return { [weak self] in self?.handlers[id] = nil }
    }

    // MARK: - Requests

    public func execute(_ request: LeoClientToolRequest, on host: LeoHostID) async -> LeoClientToolOutcome {
        let key = LeoAgentBrowserKey(host: host, agent: request.agent)
        guard let browser = browserMaking(key) else { return .failure(unavailable.clientToolError) }
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

    /// `host` was removed (or unpaired): every browser on it closes.
    public func machineRemoved(_ host: LeoHostID) {
        browsers.keys.filter { $0.host == host }.forEach(closeBrowser)
    }

    /// The agent stopped: its browser closes.
    public func agentStopped(_ key: LeoAgentBrowserKey) {
        closeBrowser(for: key)
    }

    /// `host` listed its agents (`statuses` by name) and, when it reports
    /// them, its dispatches' ids: browsers of agents that stopped or are no
    /// longer listed close. Dispatch browsers stay when `dispatches` is nil.
    public func agentsListed(on host: LeoHostID, statuses: [String: LeoAgentStatus], dispatches: Set<String>?) {
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

    private func browserMaking(_ key: LeoAgentBrowserKey) -> (any LeoAgentBrowserRunning)? {
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
