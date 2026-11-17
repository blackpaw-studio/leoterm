import ComposableArchitecture
import Foundation
import LeoKit

/// A paired daemon as the agent browser serves it: where to reach its
/// client-tools relay, and whether its `hello` advertised `client_tools`.
public struct ClientToolsMachine: Equatable, Sendable {
    public let daemonID: String
    /// The daemon's name, as the "<machine>'s localhost" copy names it.
    public let name: String
    public let endpoint: LeoRemoteEndpoint
    public let advertisesClientTools: Bool

    public init(daemonID: String, name: String, endpoint: LeoRemoteEndpoint, advertisesClientTools: Bool) {
        self.daemonID = daemonID
        self.name = name
        self.endpoint = endpoint
        self.advertisesClientTools = advertisesClientTools
    }
}

/// Leo for iOS as a `browser` client-tools provider (B-305): each paired
/// daemon that advertises `client_tools` gets a provider stream, and every
/// claimed call runs in the agent's browser on this iPhone. The app wires
/// the live value to its WebKit browsers; the default is inert.
@DependencyClient
public struct ClientToolsClient: Sendable {
    /// The daemon connected (its `hello` landed).
    public var connected: @Sendable (_ machine: ClientToolsMachine) async -> Void
    /// The daemon was unpaired: its stream stops and its browsers close.
    public var removed: @Sendable (_ daemonID: String) async -> Void
    /// The daemon listed its agents: browsers of stopped or gone agents close.
    public var agentsListed: @Sendable (_ daemonID: String, _ statuses: [String: LeoAgentStatus]) async -> Void
    /// Settings > Agent browser on this iPhone. Off stops every stream and
    /// closes every browser (their data stores stay).
    public var setEnabled: @Sendable (_ isEnabled: Bool) async -> Void
    /// The app is leaving the foreground: calls in flight are answered
    /// `cancelled`, then every stream closes. Returns once that's done.
    public var suspend: @Sendable () async -> Void
    /// The app is active again: streams reopen and pending calls are claimed.
    public var resume: @Sendable () async -> Void
    /// The pane's own control events for an agent's browser (Done,
    /// Decline, Hand Back, Take Control).
    public var control: @Sendable (_ agent: AgentRef, _ event: LeoBrowserControl.Event) async -> Void
    /// The agent's browser for its pane, made with a blank tab if it has
    /// none; nil when this iPhone can't run one (the setting is off).
    public var openBrowser: @MainActor @Sendable (_ agent: AgentRef) -> (any LeoAgentBrowserRunning)? = { _ in nil }
}

extension ClientToolsClient: DependencyKey {
    /// Does nothing: no streams, no browsers.
    public static let inert = ClientToolsClient(
        connected: { _ in }, removed: { _ in }, agentsListed: { _, _ in }, setEnabled: { _ in },
        suspend: {}, resume: {}, control: { _, _ in }, openBrowser: { _ in nil }
    )

    /// Inert until the app installs its runtime (`live(runtime:holdingBackground:)`).
    public static let liveValue = inert
    /// Inert, so the many reducers that only pass through it need no
    /// overrides; tests of the browser override what they check.
    public static let testValue = inert

    /// The client over `runtime`. `holdingBackground` keeps the app running
    /// while `suspend` answers in-flight calls (iOS: a background task).
    public static func live(
        runtime: ClientToolsRuntime,
        holdingBackground: @escaping @Sendable (_ work: @escaping @Sendable () async -> Void) async -> Void = { await $0() }
    ) -> Self {
        ClientToolsClient(
            connected: { machine in await runtime.connected(machine) },
            removed: { id in await runtime.removed(id) },
            agentsListed: { id, statuses in await runtime.agentsListed(id, statuses: statuses) },
            setEnabled: { isEnabled in await runtime.setEnabled(isEnabled) },
            suspend: { await holdingBackground { await runtime.suspend() } },
            resume: { await runtime.resume() },
            control: { agent, event in await runtime.control(agent, event) },
            openBrowser: { runtime.openBrowser(for: $0) }
        )
    }
}

extension DependencyValues {
    public var clientTools: ClientToolsClient {
        get { self[ClientToolsClient.self] }
        set { self[ClientToolsClient.self] = newValue }
    }
}

extension SharedKey where Self == AppStorageKey<Bool>.Default {
    /// Settings > Agent browser on this iPhone; on by default, as on the Mac.
    public static var agentBrowserEnabled: Self { Self[.appStorage("agentBrowserEnabled"), default: true] }
}
