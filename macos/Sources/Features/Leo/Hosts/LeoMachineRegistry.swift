import AppKit
import Combine
import Foundation
import LeoKit

/// Every configured machine, connected at once: This Mac's local socket
/// plus one SSH tunnel per enabled remote. Each machine has its own
/// connection, generation and retry schedule, so a machine that fails,
/// hangs, or is removed or disabled never blocks or tears down another.
///
/// A failed machine retries on its own with backoff (1s, 2s, 4s … at most
/// 60s apart), at once when the app becomes active, and on demand.
@MainActor final class LeoMachineRegistry: ObservableObject {
    /// Blocks until `teardown` finishes or `bound` elapses; true if it finished.
    typealias TeardownWait = @Sendable (_ teardown: Task<Void, Never>, _ bound: Duration) -> Bool

    static let defaultTeardownBound: Duration = .seconds(3)
    static let maximumRetryDelay: Duration = .seconds(60)

    /// This Mac first, then every remote in Settings order, enabled or not.
    @Published private(set) var machines: [LeoHostID] = [.local]
    @Published private(set) var flavor: LeoAPIFlavor = .legacy
    @Published private var states: [LeoHostID: LeoHostConnectionState] = [:]

    let environment: LeoMachineConnectionEnvironment
    private let store: LeoHostStore
    private let sleep: @Sendable (Duration) async throws -> Void
    private let activationCenter: NotificationCenter
    private let teardownBound: Duration
    private let waitForTeardown: TeardownWait
    private let connectionTarget: (LeoHostID, Int, LeoHostConnectionState) -> Void

    /// Every remote machine's saved configuration, in Settings order.
    private(set) var configurations: [LeoHostConfiguration] = []
    private var connections: [LeoHostID: LeoMachineConnection] = [:]
    private var generations: [LeoHostID: Int] = [:]
    private var latestGeneration = 0
    private var failedAttempts: [LeoHostID: Int] = [:]
    private var pendingRetries: [LeoHostID: Task<Void, Never>] = [:]
    /// Teardowns of retired connections by configuration id, which names
    /// the machine's sockets: its next connection (after an edit, a rename,
    /// or a remove and re-add) launches only once the old tunnel is gone.
    private var retiredTeardowns: [UUID: Task<Void, Never>] = [:]
    private var activationObserver: NSObjectProtocol?
    private var isStarted = false
    private var isShutDown = false

    /// `connectionTarget` fires synchronously for every state a machine's
    /// current connection publishes, tagged with that attempt's generation.
    init(
        store: LeoHostStore,
        environment: LeoMachineConnectionEnvironment,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        activationCenter: NotificationCenter = .default,
        teardownBound: Duration = LeoMachineRegistry.defaultTeardownBound,
        waitForTeardown: @escaping TeardownWait = LeoMachineRegistry.blockingWait,
        connectionTarget: @escaping (LeoHostID, Int, LeoHostConnectionState) -> Void = { _, _, _ in }
    ) {
        self.store = store
        self.environment = environment
        self.sleep = sleep
        self.activationCenter = activationCenter
        self.teardownBound = teardownBound
        self.waitForTeardown = waitForTeardown
        self.connectionTarget = connectionTarget
        loadConfigurations()
        // `queue: nil`, then hop: a `queue: .main` observer would make the
        // poster wait on the main thread (see the quit-deadlock notes).
        activationObserver = activationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.retryFailedMachines() }
        }
    }

    deinit {
        activationObserver.map(activationCenter.removeObserver)
    }

    // MARK: - Reading

    /// Nil for a machine that isn't configured.
    func status(for host: LeoHostID) -> LeoMachineStatus? {
        guard machines.contains(host) else { return nil }
        if case .remote = host, configuration(for: host)?.isEnabled == false { return .disabled }
        switch states[host] ?? .connecting {
        case .connecting: return .connecting
        case .connected: return .connected
        case .failed(let message, _): return .failed(message)
        }
    }

    /// The full state of the machine's current connection, with its socket
    /// path or failure hint; nil before it connects and for a disabled or
    /// unknown machine.
    func connectionState(for host: LeoHostID) -> LeoHostConnectionState? {
        states[host]
    }

    /// Every machine's connection state as it changes, emitted before it is
    /// stored (like any `@Published`): read the emitted value, not the
    /// registry.
    var connectionStates: AnyPublisher<[LeoHostID: LeoHostConnectionState], Never> { $states.eraseToAnyPublisher() }

    /// The saved configuration of a remote machine; nil for This Mac.
    func configuration(for host: LeoHostID) -> LeoHostConfiguration? {
        guard case .remote(let name) = host else { return nil }
        return configurations.first { $0.name == name }
    }

    /// Changes whenever `host`'s connection is replaced or torn down, and
    /// never because of another machine. Generations come from one counter,
    /// so a machine removed and added again never reuses one.
    func generation(for host: LeoHostID) -> Int {
        generations[host] ?? 0
    }

    /// The Machines settings pane's draft. Saving it reloads only the
    /// machines whose settings changed; Test Connection never touches a
    /// live connection.
    func makeSettingsModel() -> LeoMachinesSettingsModel {
        LeoMachinesSettingsModel(store: store, tester: LeoMachineConnectionTester(environment: environment)) { [weak self] in
            self?.reload()
        }
    }

    // MARK: - Lifecycle

    /// Connects This Mac and every enabled remote. Runs once.
    func start(flavor: LeoAPIFlavor) {
        guard !isStarted, !isShutDown else { return }
        isStarted = true
        self.flavor = flavor
        open(.local)
        reload()
    }

    /// Re-reads the saved machines after Settings saves. A removed or
    /// disabled machine is torn down, an edited one reconnects with its new
    /// settings, a new or re-enabled one connects, and every other machine
    /// is left exactly as it is.
    func reload() {
        guard !isShutDown else { return }
        loadConfigurations()
        guard isStarted else { return }
        let wanted = Dictionary(configurations.filter(\.isEnabled).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let stale = connections.compactMap { host, connection -> LeoHostID? in
            guard case .remote(let configuration) = connection.target else { return nil }
            return wanted[configuration.name] == configuration ? nil : host
        }
        stale.forEach(retire)
        for configuration in configurations where configuration.isEnabled && connections[.remote(configuration.name)] == nil {
            open(.remote(configuration))
        }
    }

    /// Connects `host` again now, replacing any attempt in flight, and starts
    /// its backoff over: a header's Reconnect, or This Mac after the app
    /// restarted its own daemon. A disabled or unknown machine is ignored.
    func reconnect(_ host: LeoHostID) {
        guard !isShutDown, let connection = connections[host] else { return }
        cancelRetry(for: host)
        failedAttempts[host] = nil
        connection.connect()
    }

    /// Reconnects every enabled machine that isn't connected, including one
    /// still trying (Agents ▸ Reconnect).
    func reconnectUnavailable() {
        connections.filter { !Self.isConnected($0.value.state) }.keys.forEach(reconnect)
    }

    /// The quit hook: tears every tunnel down at once (and waits on any
    /// still retiring from a Settings edit), blocking until they are all
    /// confirmed gone, bounded by `teardownBound` in total (never per
    /// machine). Returns false when the bound ran out first; a child still
    /// exiting then clears its own reap record when it does exit.
    @discardableResult
    func shutdown() -> Bool {
        guard !isShutDown else { return true }
        isShutDown = true
        pendingRetries.values.forEach { $0.cancel() }
        pendingRetries = [:]
        let retiring = Array(connections.values)
        let barriers = retiring.map { $0.shutdown() } + retiredTeardowns.values
        retiring.forEach { generations[$0.host] = nextGeneration() }
        let teardown = Task.detached(priority: .userInitiated) {
            for barrier in barriers { await barrier.value }
        }
        let finished = waitForTeardown(teardown, teardownBound)
        if finished { retiring.forEach { $0.clearOrphanRecord() } }
        return finished
    }

    /// The production `TeardownWait`: a semaphore with a timeout.
    nonisolated static func blockingWait(for teardown: Task<Void, Never>, upTo bound: Duration) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await teardown.value
            semaphore.signal()
        }
        let (seconds, attoseconds) = bound.components
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        return semaphore.wait(timeout: .now() + .nanoseconds(nanoseconds)) == .success
    }

    /// The wait before retry number `failures + 1`: 1s, doubling, at most 60s.
    nonisolated static func retryDelay(afterFailures failures: Int) -> Duration {
        min(.seconds(1 << min(failures, 6)), maximumRetryDelay)
    }

    // MARK: - Connections

    private func loadConfigurations() {
        configurations = store.load()
        machines = [.local] + configurations.map { .remote($0.name) }
    }

    private func open(_ target: LeoMachineConnection.Target) {
        let host = target.host
        let connection = LeoMachineConnection(
            target: target,
            environment: environment,
            previousTeardown: target.configurationID.flatMap { retiredTeardowns.removeValue(forKey: $0) },
            nextGeneration: { [weak self] in self?.nextGeneration() ?? 0 },
            onState: { [weak self] generation, state in self?.receive(state, generation: generation, for: host) }
        )
        connections[host] = connection
        connection.connect()
    }

    /// Tears down `host`'s connection only; its in-flight work reads as stale.
    private func retire(_ host: LeoHostID) {
        cancelRetry(for: host)
        failedAttempts[host] = nil
        states[host] = nil
        guard let connection = connections.removeValue(forKey: host) else { return }
        let teardown = connection.shutdown()
        if let id = connection.target.configurationID { retiredTeardowns[id] = teardown }
        generations[host] = nextGeneration()
    }

    private func nextGeneration() -> Int {
        latestGeneration += 1
        return latestGeneration
    }

    private func receive(_ state: LeoHostConnectionState, generation: Int, for host: LeoHostID) {
        guard !isShutDown, connections[host]?.generation == generation else { return }
        states[host] = state
        generations[host] = generation
        switch state {
        case .connected:
            failedAttempts[host] = nil
            cancelRetry(for: host)
        case .failed:
            scheduleRetry(for: host)
        case .connecting:
            break
        }
        connectionTarget(host, generation, state)
    }

    // MARK: - Retry

    private func scheduleRetry(for host: LeoHostID) {
        cancelRetry(for: host)
        let failures = failedAttempts[host, default: 0]
        failedAttempts[host] = failures + 1
        let delay = Self.retryDelay(afterFailures: failures)
        let sleep = sleep
        pendingRetries[host] = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.retryNow(host)
        }
    }

    private func cancelRetry(for host: LeoHostID) {
        pendingRetries.removeValue(forKey: host)?.cancel()
    }

    private func retryNow(_ host: LeoHostID) {
        pendingRetries[host] = nil
        guard !isShutDown, let connection = connections[host], Self.isFailed(connection.state) else { return }
        connection.connect()
    }

    /// App activation: every failed machine tries again now. Its backoff
    /// keeps counting, so a machine that is still down waits longer next time.
    private func retryFailedMachines() {
        guard !isShutDown else { return }
        connections.filter { Self.isFailed($0.value.state) }.keys.forEach { host in
            cancelRetry(for: host)
            connections[host]?.connect()
        }
    }

    private static func isConnected(_ state: LeoHostConnectionState) -> Bool {
        if case .connected = state { return true }
        return false
    }

    private static func isFailed(_ state: LeoHostConnectionState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
