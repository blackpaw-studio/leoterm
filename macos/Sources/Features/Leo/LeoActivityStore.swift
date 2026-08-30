import Foundation

/// App-owned, shared observer of per-agent activity (working/idle/unknown),
/// sourced from the Leo daemon's local observability endpoint.
///
/// Localhost-only by design: the endpoint is always `127.0.0.1`, so agents
/// hosted on a remote machine (see `LeoHost`) never have a live activity
/// signal from this store — callers should treat `.unknown` for a remote
/// agent as "no data available", not "confirmed idle".
@MainActor
final class LeoActivityStore: ObservableObject {
    @Published private(set) var activity: [String: AgentActivity] = [:]
    @Published private(set) var isConnected: Bool = false

    private let client: LeoActivityClient
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - config: The resolved local observability endpoint, or `nil` when
    ///     unavailable (no token, or `web.enabled: false`). Resolve this via
    ///     `LeoObserveConfigLoader.load()`.
    ///   - transport: Injected so callers (and tests) can supply a stub
    ///     instead of a real `URLSession`.
    init(config: LeoObserveConfig?, transport: LeoActivityTransport = URLSessionActivityTransport()) {
        self.client = LeoActivityClient(config: config, transport: transport)
    }

    /// The current activity for `name`, defaulting to `.unknown` for any
    /// agent not yet reported by the daemon (including remote-host agents).
    func activity(for name: String) -> AgentActivity {
        activity[name] ?? .unknown
    }

    /// Start observing. Idempotent: calling this while already started is a
    /// no-op.
    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            for await update in await self.client.activityUpdates() {
                self.activity = update
                self.isConnected = true
            }
            self.isConnected = false
        }
    }

    /// Stop observing and tear down the underlying network task.
    func stop() {
        task?.cancel()
        task = nil
        isConnected = false
    }
}
