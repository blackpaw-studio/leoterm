import Foundation
import LeoKit

/// The iPhone's agent browsers wired to its paired daemons: the registry,
/// one client-tools session per daemon, the setting and the app's
/// foreground state over all of them (B-305).
///
/// iOS is the fallback provider: a connected Mac claims first, so this
/// device waits `claimDelay` before claiming a call nobody owns. A daemon's
/// session follows its connection and keeps its own backoff; its browsers
/// outlive a reconnect and close when its listing drops their agent.
@MainActor public final class ClientToolsRuntime {
    /// Makes the agent's browser; `machine` names its daemon for the
    /// "<machine>'s localhost" copy. Nil when it can't be made.
    public typealias MakeBrowser = @MainActor (_ key: LeoAgentBrowserKey, _ machine: String) -> (any LeoAgentBrowserRunning)?
    public typealias MakeClient = @MainActor (ClientToolsMachine) -> any LeoClientToolsProviding

    /// How long an unowned call waits for a connected Mac to claim it.
    public static let fallbackClaimDelay = Duration.milliseconds(1_500)

    public private(set) var browsers: LeoAgentBrowsers!
    private let makeClient: MakeClient
    private let claimDelay: Duration
    private let sleep: LeoClientToolsSession.Sleep
    private var sessions: [String: (machine: ClientToolsMachine, session: LeoClientToolsSession)] = [:]
    private var machineNames: [String: String] = [:]
    private var isEnabled = true
    private var isSuspended = false
    /// Told when the app leaves or returns to the foreground (each browser's
    /// pending permission asks, content processes).
    public var onForegroundChange: (@MainActor (_ isForeground: Bool) -> Void)?

    public init(
        makeBrowser: @escaping MakeBrowser,
        makeClient: @escaping MakeClient = { LeoClientToolsClient(transport: LeoClientToolsHTTPTransport(endpoint: $0.endpoint)) },
        claimDelay: Duration = fallbackClaimDelay,
        sleep: @escaping LeoClientToolsSession.Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.makeClient = makeClient
        self.claimDelay = claimDelay
        self.sleep = sleep
        browsers = LeoAgentBrowsers(
            makeBrowser: { [unowned self] key in
                guard isEnabled, case .remote(let daemonID) = key.host else { return nil }
                return makeBrowser(key, machineNames[daemonID] ?? daemonID)
            },
            unavailable: LeoBrowserError(.navigationFailed, "The agent browser is off on this iPhone")
        )
    }

    /// The agent's browser, if it has one.
    public func browser(for agent: AgentRef) -> (any LeoAgentBrowserRunning)? {
        browsers.model(for: Self.key(agent))
    }

    /// The agent's browser, made if needed, with a blank tab.
    public func openBrowser(for agent: AgentRef) -> (any LeoAgentBrowserRunning)? {
        browsers.openModel(for: Self.key(agent))
    }

    public static func key(_ agent: AgentRef) -> LeoAgentBrowserKey {
        LeoAgentBrowserKey(host: .remote(agent.daemonID), agent: agent.name)
    }

    // MARK: - Daemons

    public func connected(_ machine: ClientToolsMachine) {
        machineNames[machine.daemonID] = machine.name
        if let current = sessions[machine.daemonID], current.machine.endpoint == machine.endpoint {
            sessions[machine.daemonID]?.machine = machine
            current.session.setAdvertised(machine.advertisesClientTools)
            return
        }
        sessions.removeValue(forKey: machine.daemonID)?.session.stop()
        let session = LeoClientToolsSession(
            host: .remote(machine.daemonID), client: makeClient(machine), executor: browsers,
            isPlatformSupported: true, claimDelay: claimDelay, sleep: sleep
        )
        session.setEnabled(isEnabled)
        session.setAdvertised(machine.advertisesClientTools)
        sessions[machine.daemonID] = (machine, session)
        guard !isSuspended else { return }
        session.start()
    }

    public func removed(_ daemonID: String) {
        sessions.removeValue(forKey: daemonID)?.session.stop()
        machineNames[daemonID] = nil
        browsers.machineRemoved(.remote(daemonID))
    }

    public func agentsListed(_ daemonID: String, statuses: [String: LeoAgentStatus]) {
        browsers.agentsListed(on: .remote(daemonID), statuses: statuses, dispatches: nil)
    }

    // MARK: - Setting and foreground

    public func setEnabled(_ isEnabled: Bool) {
        guard isEnabled != self.isEnabled else { return }
        self.isEnabled = isEnabled
        sessions.values.forEach { $0.session.setEnabled(isEnabled) }
        guard !isEnabled else { return }
        browsers.keys.forEach(browsers.closeBrowser)
    }

    public func suspend() async {
        guard !isSuspended else { return }
        isSuspended = true
        onForegroundChange?(false)
        let running = sessions.values.map(\.session)
        // A resume meanwhile has already resumed every session; suspending
        // the rest would leave them off while the runtime is foreground.
        for session in running {
            guard isSuspended else { return }
            await session.suspend()
        }
    }

    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        onForegroundChange?(true)
        for (_, session) in sessions.values {
            session.start()
            session.resume()
        }
    }

    public func control(_ agent: AgentRef, _ event: LeoBrowserControl.Event) {
        browser(for: agent)?.control.send(event)
    }
}
