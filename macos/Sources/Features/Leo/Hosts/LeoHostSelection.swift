import Combine
import Foundation

/// The connection state of the currently *selected* host. Localhost is
/// always `.connected` to the local daemon socket; a remote host's state
/// reflects the app-owned SSH tunnel `LeoHostSelection` is managing for it.
enum LeoHostConnectionState: Equatable, Sendable {
    case connecting
    case connected(socketPath: String)
    case failed(message: String, hint: String?)
}

enum LeoHostSelectionError: Error, Equatable, Sendable {
    case homeResolutionFailed(String)
}

/// Owns exactly one SSH tunnel (`LeoTunnel`) for the selected remote host, if
/// any. Every `select(_:)` bumps a `generation` counter; every async step
/// re-checks it before publishing, so a stale connect attempt superseded by a
/// newer selection can never clobber it and never leaves more than one live
/// child process running. No timers, no auto-reconnect, no backoff -- a dead
/// tunnel publishes `.failed` and stays there until the user retries.
@MainActor final class LeoHostSelection: ObservableObject {
    @Published private(set) var hosts: [LeoHostConfiguration] = []
    @Published private(set) var selected: LeoHostID
    @Published private(set) var state: LeoHostConnectionState
    @Published private(set) var flavor: LeoAPIFlavor = .legacy

    private let store: LeoHostStore
    private let defaults: UserDefaults
    private let runner: any LeoProcessRunning
    private let sshExecutable: URL
    private let transport: any LeoDaemonTransport
    private let orphanStore: LeoTunnelOrphanStore
    private let fileManager: FileManager
    private let localSocketPath: String
    private let installTarget: (LeoHostID) -> Void

    private var generation = 0
    private var currentTunnel: LeoTunnel?

    init(
        store: LeoHostStore,
        defaults: UserDefaults,
        runner: any LeoProcessRunning = LeoProcessRunner(),
        sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        transport: any LeoDaemonTransport = LeoUnixSocketTransport(),
        orphanStore: LeoTunnelOrphanStore? = nil,
        fileManager: FileManager = .default,
        localSocketPath: String = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath,
        installTarget: @escaping (LeoHostID) -> Void = { _ in }
    ) {
        self.store = store
        self.defaults = defaults
        self.runner = runner
        self.sshExecutable = sshExecutable
        self.transport = transport
        self.orphanStore = orphanStore ?? LeoTunnelOrphanStore(defaults: defaults)
        self.fileManager = fileManager
        self.localSocketPath = localSocketPath
        self.installTarget = installTarget
        if let value = defaults.string(forKey: "leo.selectedHost"), value != "localhost" {
            selected = .remote(value)
        } else {
            selected = .local
        }
        state = .connected(socketPath: localSocketPath)
    }

    var legacyTooltip: String? { flavor == .legacy ? "leo 0.29+ required for remote hosts" : nil }

    /// The configuration backing the currently selected remote host, if any
    /// -- used by the UI for e.g. the "Open SSH" hint action.
    var selectedConfiguration: LeoHostConfiguration? {
        guard case .remote(let name) = selected else { return nil }
        return hosts.first { $0.name == name }
    }

    func start(flavor: LeoAPIFlavor) async {
        self.flavor = flavor
        hosts = store.load()
        select(selected)
    }

    /// Selects `host`. Localhost is published as `.connected` immediately.
    /// A remote host starts a fresh app-owned SSH tunnel connect attempt;
    /// any tunnel the previous selection was using is torn down off the main
    /// actor. Never blocks the caller.
    func select(_ host: LeoHostID) {
        selected = host
        defaults.set(host.displayName, forKey: "leo.selectedHost")
        installTarget(host)

        generation += 1
        let myGeneration = generation
        let previousTunnel = currentTunnel
        currentTunnel = nil

        guard case .remote(let name) = host else {
            state = .connected(socketPath: localSocketPath)
            Task { [weak self] in await self?.teardown(previousTunnel) }
            return
        }

        state = .connecting
        guard let configuration = hosts.first(where: { $0.name == name }) else {
            state = .failed(message: "Unknown host \(name)", hint: nil)
            Task { [weak self] in await self?.teardown(previousTunnel) }
            return
        }

        Task { [weak self] in
            await self?.connect(configuration: configuration, generation: myGeneration, previousTunnel: previousTunnel)
        }
    }

    /// Re-runs `select(selected)` -- there is no separate coalescing path;
    /// a retry is just a fresh, generation-guarded connect attempt.
    func retry() { select(selected) }

    /// Synchronously tears down the current tunnel. Called from the
    /// AppDelegate quit hook, which must not return until the child is gone.
    func shutdown() {
        currentTunnel?.terminateAndWait()
        currentTunnel = nil
    }

    private func teardown(_ tunnel: LeoTunnel?) async {
        guard let tunnel else { return }
        await Task.detached { tunnel.terminateAndWait() }.value
    }

    private func connect(configuration: LeoHostConfiguration, generation myGeneration: Int, previousTunnel: LeoTunnel?) async {
        await teardown(previousTunnel)
        guard generation == myGeneration else { return }

        var launchedTunnel: LeoTunnel?
        do {
            let remoteSocketPath = try await resolveRemoteSocketPath(configuration: configuration)
            let localPath = try prepareLocalSocketPath(configuration: configuration)
            let arguments = try LeoSSHCommand(configuration: configuration).tunnelArguments(
                localSocketPath: localPath, remoteSocketPath: remoteSocketPath
            )

            // A newer select()/retry() -- itself synchronous up to this
            // point -- may have bumped `generation` while the async work
            // above was in flight. Check again before ever constructing (let
            // alone starting) a tunnel: `currentTunnel` must only ever be
            // assigned by the single generation that's still current, or two
            // tunnels could end up live at once with `currentTunnel`
            // referencing only one of them.
            guard generation == myGeneration else { return }

            let tunnel = LeoTunnel(
                executable: sshExecutable,
                arguments: arguments,
                localSocketPath: localPath,
                healthProbe: makeHealthProbe()
            )
            launchedTunnel = tunnel
            let orphanBox = LeoTunnelOrphanBox()
            let orphanStore = orphanStore
            tunnel.onExit = { [weak self] exit in
                if let record = orphanBox.value { orphanStore.clear(matching: record) }
                Task { @MainActor in self?.handleExit(exit, generation: myGeneration, tunnel: tunnel, configuration: configuration) }
            }
            currentTunnel = tunnel

            try await tunnel.start()

            if let pid = tunnel.pid, let startTime = tunnel.processStartTime {
                let record = LeoTunnelOrphanRecord(pid: pid, startTime: startTime, socketPath: localPath)
                orphanBox.value = record
                orphanStore.record(record)
            }

            guard generation == myGeneration else {
                await Task.detached { tunnel.terminateAndWait() }.value
                return
            }
            state = .connected(socketPath: localPath)
        } catch {
            if let launchedTunnel, currentTunnel === launchedTunnel { currentTunnel = nil }
            guard generation == myGeneration else { return }
            let (message, hint) = Self.describe(error, configuration: configuration)
            state = .failed(message: message, hint: hint)
        }
    }

    /// Fires off-main from `LeoTunnel`; hops to main and only publishes if
    /// this is still the current generation AND the exiting tunnel is still
    /// the one currently tracked (a newer `select` may already own a
    /// different tunnel by the time this arrives).
    private func handleExit(_ exit: LeoTunnelExit, generation myGeneration: Int, tunnel: LeoTunnel, configuration: LeoHostConfiguration) {
        guard generation == myGeneration, currentTunnel === tunnel else { return }
        currentTunnel = nil
        let message = exit.stderrTail.isEmpty ? "ssh exited (\(exit.status))" : exit.stderrTail
        state = .failed(message: message, hint: Self.hint(forStderr: exit.stderrTail, target: configuration.sshTarget))
    }

    private func resolveRemoteSocketPath(configuration: LeoHostConfiguration) async throws -> String {
        let command = LeoSSHCommand(configuration: configuration)
        guard configuration.remoteSocketPath.hasPrefix("~/") else {
            return try command.resolvedRemoteSocketPath(home: "")
        }
        let arguments = try command.remoteHomeCommand()
        let result = try await runner.run(executable: sshExecutable.path, arguments: arguments, timeout: 15)
        guard result.status == 0 else {
            throw LeoHostSelectionError.homeResolutionFailed(String(data: result.stderr, encoding: .utf8) ?? "")
        }
        let home = String(data: result.stdout, encoding: .utf8) ?? ""
        return try command.resolvedRemoteSocketPath(home: home)
    }

    private func prepareLocalSocketPath(configuration: LeoHostConfiguration) throws -> String {
        let directory = fileManager.temporaryDirectory.appendingPathComponent("leoterm", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(configuration.localSocketFileName).path
    }

    private func makeHealthProbe() -> @Sendable (String) async throws -> Bool {
        let transport = transport
        return { path in
            let response = try await transport.send(LeoHTTPRequest(method: "GET", path: "/health"), socketPath: path, timeout: 1)
            return response.status == 200
        }
    }

    private static func describe(_ error: Error, configuration: LeoHostConfiguration) -> (message: String, hint: String?) {
        let stderrTail: String
        switch error {
        case let error as LeoTunnelError:
            switch error {
            case .launchFailed(let message): stderrTail = message
            case .exitedBeforeReady(_, let tail), .notReady(let tail): stderrTail = tail
            }
        case let error as LeoHostSelectionError:
            if case .homeResolutionFailed(let tail) = error { stderrTail = tail } else { stderrTail = String(describing: error) }
        default:
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

/// Thread-safe box for the orphan record a tunnel's `onExit` (fired off the
/// main actor) needs to clear once the process it describes has exited.
private final class LeoTunnelOrphanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: LeoTunnelOrphanRecord?
    var value: LeoTunnelOrphanRecord? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}
