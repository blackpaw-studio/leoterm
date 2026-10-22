import Foundation
import OSLog
import LeoKit

/// One machine's connection, for one fixed target: the local daemon socket
/// for This Mac, or an app-owned SSH tunnel for a remote. Editing a remote
/// replaces its whole connection; `LeoMachineRegistry` owns one per machine.
///
/// Every `connect()` takes a new generation, and every async step re-checks
/// it before publishing, so a superseded attempt never publishes and never
/// leaves a second child running. A connection never retries on its own: a
/// dead tunnel publishes `.failed` and the registry decides when to retry.
///
/// Every teardown chains onto one barrier (`retiring`), and a connect
/// attempt awaits that barrier before it builds a tunnel: a rapid
/// reconnect can never have two children alive at once.
@MainActor final class LeoMachineConnection {
    enum Target: Equatable {
        case local
        case remote(LeoHostConfiguration)

        var host: LeoHostID {
            switch self {
            case .local: .local
            case .remote(let configuration): .remote(configuration.name)
            }
        }
    }

    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    let target: Target
    private(set) var state: LeoHostConnectionState
    private(set) var generation = 0

    private let environment: LeoMachineConnectionEnvironment
    private let nextGeneration: () -> Int
    private let publishState: (Int, LeoHostConnectionState) -> Void
    private var currentTunnel: (any LeoTunnelProcess)?
    /// The reap record of the newest tunnel launched, filled in (off the main
    /// actor) the moment it launches.
    private var currentOrphan: LeoTunnelOrphanBox?
    private var retiring: Task<Void, Never>?
    private var isShutDown = false

    /// `nextGeneration` hands out the generation for each attempt; the
    /// registry shares one counter across machines, so a machine removed and
    /// added again never reuses a generation. `onState` fires synchronously
    /// for every state change, tagged with the attempt's generation.
    init(
        target: Target,
        environment: LeoMachineConnectionEnvironment,
        nextGeneration: @escaping () -> Int,
        onState: @escaping (_ generation: Int, _ state: LeoHostConnectionState) -> Void
    ) {
        self.target = target
        self.environment = environment
        self.nextGeneration = nextGeneration
        publishState = onState
        state = .connecting
    }

    var host: LeoHostID { target.host }

    /// Starts a fresh attempt, replacing any in flight. This Mac publishes
    /// `.connected` at once; a remote tears its previous tunnel down (off
    /// the main actor) and then connects. Never blocks the caller.
    func connect() {
        guard !isShutDown else { return }
        generation = nextGeneration()
        let myGeneration = generation
        let barrier = beginTeardown()
        guard case .remote(let configuration) = target else {
            publish(.connected(socketPath: environment.localSocketPath), generation: myGeneration)
            return
        }
        publish(.connecting, generation: myGeneration)
        Task { [weak self] in
            await self?.run(configuration, generation: myGeneration, barrier: barrier)
        }
    }

    /// Retires the connection for good and starts tearing its tunnel down.
    /// The returned barrier resolves once the child is confirmed gone. No
    /// later `connect()` launches anything, and nothing more is published.
    func shutdown() -> Task<Void, Never> {
        isShutDown = true
        return beginTeardown()
    }

    /// Once `shutdown()`'s barrier has resolved the child is confirmed gone,
    /// so its reap record can go too. On a timeout the record stays for the
    /// next launch's reaper; `onExit` clears it whenever the child does exit.
    func clearOrphanRecord() {
        guard let record = currentOrphan?.value else { return }
        environment.orphanStore.clear(matching: record)
    }

    /// Chains a teardown of the current tunnel onto any teardown already in
    /// flight and returns it as the new barrier.
    private func beginTeardown() -> Task<Void, Never> {
        let previousTunnel = currentTunnel
        currentTunnel = nil
        let awaited = retiring
        let barrier = Task.detached {
            await awaited?.value
            if let previousTunnel { await LeoMachineConnection.terminate(previousTunnel) }
        }
        retiring = barrier
        return barrier
    }

    /// `terminateAndWait()` blocks (SIGTERM, up to 1s, then SIGKILL), so it
    /// runs on a GCD thread: machines tearing down at once must never hold
    /// the cooperative pool's threads.
    nonisolated static func terminate(_ tunnel: any LeoTunnelProcess) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                tunnel.terminateAndWait()
                continuation.resume()
            }
        }
    }

    private func isCurrent(_ myGeneration: Int) -> Bool {
        generation == myGeneration && !isShutDown
    }

    private func run(_ configuration: LeoHostConfiguration, generation myGeneration: Int, barrier: Task<Void, Never>) async {
        await barrier.value
        guard isCurrent(myGeneration) else { return }

        var launchedTunnel: (any LeoTunnelProcess)?
        do {
            let remoteSocketPath = try await environment.resolveRemoteSocketPath(for: configuration)
            let localPath = try environment.prepareTunnelSocketPath(for: configuration)
            // A newer connect() or shutdown() may have run while the work
            // above was in flight: check again before building a tunnel.
            guard isCurrent(myGeneration) else { return }
            let arguments = try LeoSSHCommand(configuration: configuration).tunnelArguments(
                localSocketPath: localPath,
                remoteSocketPath: remoteSocketPath,
                controlPath: environment.multiplexingControlPath(for: configuration)
            )
            let tunnel = environment.makeTunnel(LeoTunnelLaunch(
                host: host,
                executable: environment.sshExecutable,
                arguments: arguments,
                localSocketPath: localPath,
                healthProbe: environment.makeHealthProbe()
            ))
            launchedTunnel = tunnel
            let orphan = observe(tunnel, localPath: localPath, generation: myGeneration, configuration: configuration)
            currentTunnel = tunnel
            currentOrphan = orphan

            try await tunnel.start()

            // Superseded while `start()` ran, or already exited (and
            // published `.failed`) in the window before this line: a stale or
            // dead tunnel never overwrites that with `.connected`.
            guard isCurrent(myGeneration), currentTunnel === tunnel, !tunnel.hasExited else {
                if let record = orphan.value { environment.orphanStore.clear(matching: record) }
                await Self.terminate(tunnel)
                return
            }
            publish(.connected(socketPath: localPath), generation: myGeneration)
        } catch {
            Self.logger.error("connect failed host=\(configuration.name, privacy: .public) error=\(String(describing: error), privacy: .public)")
            if let launchedTunnel, currentTunnel === launchedTunnel { currentTunnel = nil }
            // The tunnel's `onExit` may already have reported this attempt.
            guard isCurrent(myGeneration), !Self.isFailed(state) else { return }
            let (message, hint) = Self.describe(error, configuration: configuration)
            publish(.failed(message: message, hint: hint), generation: myGeneration)
        }
    }

    /// Records the tunnel for the launch-time reaper as soon as it launches
    /// (before any readiness probing, so a crash mid-probe still leaves an
    /// accurate record), and clears that record when it exits.
    private func observe(
        _ tunnel: any LeoTunnelProcess, localPath: String, generation myGeneration: Int, configuration: LeoHostConfiguration
    ) -> LeoTunnelOrphanBox {
        let orphan = LeoTunnelOrphanBox()
        let orphanStore = environment.orphanStore
        tunnel.onLaunch = { pid, startTime in
            let record = LeoTunnelOrphanRecord(pid: pid, startTime: startTime, socketPath: localPath)
            orphan.value = record
            orphanStore.record(record)
        }
        // `[weak tunnel]`: the closure is stored on the tunnel itself, so a
        // strong capture would keep it (and its `Process`) alive forever.
        tunnel.onExit = { [weak self, weak tunnel] exit in
            if let record = orphan.value { orphanStore.clear(matching: record) }
            Task { @MainActor in
                guard let tunnel else { return }
                self?.handleExit(exit, generation: myGeneration, tunnel: tunnel, configuration: configuration)
            }
        }
        return orphan
    }

    /// Publishes `.failed` only if the exiting tunnel is still this
    /// connection's current one.
    private func handleExit(_ exit: LeoTunnelExit, generation myGeneration: Int, tunnel: any LeoTunnelProcess, configuration: LeoHostConfiguration) {
        guard isCurrent(myGeneration), currentTunnel === tunnel else { return }
        currentTunnel = nil
        let message = exit.stderrTail.isEmpty ? "ssh exited (\(exit.status))" : exit.stderrTail
        publish(.failed(message: message, hint: Self.hint(forStderr: exit.stderrTail, target: configuration.sshTarget)), generation: myGeneration)
    }

    private func publish(_ newState: LeoHostConnectionState, generation: Int) {
        state = newState
        Self.logger.log("publish host=\(self.host.displayName, privacy: .public) generation=\(generation) state=\(String(describing: newState), privacy: .public)")
        publishState(generation, newState)
    }

    private static func isFailed(_ state: LeoHostConnectionState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private static func describe(_ error: Error, configuration: LeoHostConfiguration) -> (message: String, hint: String?) {
        let stderrTail: String
        switch error as? LeoTunnelError {
        case .launchFailed(let message)?:
            stderrTail = message
        case .exitedBeforeReady(_, let tail)?, .notReady(let tail)?:
            stderrTail = tail
        case nil:
            stderrTail = error.localizedDescription
        }
        let message = stderrTail.isEmpty ? String(describing: error) : stderrTail
        return (message, hint(forStderr: stderrTail, target: configuration.sshTarget))
    }

    private static func hint(forStderr stderr: String, target: String) -> String? {
        if stderr.contains("Host key verification failed") {
            return "Run `ssh \(target)` once in a terminal to accept the host key"
        }
        if stderr.contains("Permission denied") {
            return "ssh needs a key or agent in BatchMode; try `ssh \(target)` in a terminal"
        }
        return nil
    }
}
