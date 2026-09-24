import Combine
import Foundation
import OSLog

/// The connection state of the currently *selected* host. Localhost is
/// always `.connected` to the local daemon socket; a remote host's state
/// reflects the app-owned SSH tunnel `LeoHostSelection` is managing for it.
enum LeoHostConnectionState: Equatable, Sendable {
    case connecting
    case connected(socketPath: String)
    case failed(message: String, hint: String?)

    var failureHint: String? {
        if case .failed(_, let hint) = self { hint } else { nil }
    }
}

enum LeoHostSelectionError: Error, Equatable, Sendable {
    case homeResolutionFailed(String)
    /// The socket directory failed `LeoControlSocketDirectory.prepare`.
    case unsafeSocketDirectory
    /// Another user's socket sits at the forwarded socket's path.
    case foreignTunnelSocket
    /// A file, directory or symlink sits at the forwarded socket's path.
    case occupiedTunnelSocketPath
}

extension LeoHostSelectionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .homeResolutionFailed(let stderr): return stderr
        case .unsafeSocketDirectory: return "The tunnel socket directory is not private"
        case .foreignTunnelSocket: return "The tunnel socket belongs to another user"
        case .occupiedTunnelSocketPath: return "Something other than a socket is at the tunnel socket path"
        }
    }
}

/// Owns exactly one SSH tunnel (`LeoTunnel`) for the selected remote host, if
/// any. Every `select(_:)` bumps a `generation` counter; every async step
/// re-checks it before publishing, so a stale connect attempt superseded by a
/// newer selection can never clobber it and never leaves more than one live
/// child process running. No timers, no auto-reconnect, no backoff -- a dead
/// tunnel publishes `.failed` and stays there until the user retries.
///
/// Every teardown is serialized through a single chained barrier
/// (`retiring`): `select()`/`retry()`/`shutdown()` each chain their own
/// teardown onto whatever teardown is already in flight, and a connect
/// attempt always awaits that SAME barrier before ever constructing a new
/// tunnel. Without this, clearing `currentTunnel` synchronously at the top of
/// `select()` would let a rapid A->B->A sequence launch the second A while
/// the first A's teardown (kicked off by the A->B transition) is still
/// running -- two live children at once.
@MainActor final class LeoHostSelection: ObservableObject {
    static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    @Published private(set) var hosts: [LeoHostConfiguration] = []
    @Published private(set) var selected: LeoHostID
    @Published private(set) var state: LeoHostConnectionState
    @Published private(set) var flavor: LeoAPIFlavor = .legacy

    private let store: LeoHostStore
    private let defaults: UserDefaults
    private let runner: any LeoProcessRunning
    let sshExecutable: URL
    private let transport: any LeoDaemonTransport
    private let orphanStore: LeoTunnelOrphanStore
    private let localSocketPath: String
    /// `~/.leo/state/leoterm/`, where the forwarded socket lived before
    /// B-021. Only ever searched for this app's own stale sockets.
    let legacySocketDirectory: URL
    /// Holds the forwarded daemon socket and the ControlMaster sockets;
    /// see `LeoControlSocketDirectory`.
    let controlSocketDirectory: URL
    /// Scopes the ControlMaster socket name to this app bundle; see
    /// `LeoHostConfiguration.controlSocketFileName(instance:)`.
    let controlSocketInstance: String
    /// The only user whose control socket this app will use or remove;
    /// injectable because tests can't create another user's socket.
    let controlSocketOwner: uid_t
    static let defaultControlSocketInstance = LeoHostConfiguration.controlSocketInstance(
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "studio.blackpaw.leo"
    )
    /// Fired synchronously for every state transition, tagged with the
    /// `(host, generation)` it belongs to -- `LeoRuntime` uses this to know
    /// exactly when a *switch* happened (a new `(host, generation)` pair)
    /// versus a phase update for the connection already in flight.
    private let connectionTarget: (LeoHostID, Int, LeoHostConnectionState) -> Void

    private var generation = 0
    private var currentTunnel: LeoTunnel?
    private var currentOrphanRecord: LeoTunnelOrphanRecord?
    private var retiring: Task<Void, Never>?
    private var isShutDown = false

    init(
        store: LeoHostStore,
        defaults: UserDefaults,
        runner: any LeoProcessRunning = LeoProcessRunner(),
        sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        transport: any LeoDaemonTransport = LeoUnixSocketTransport(),
        orphanStore: LeoTunnelOrphanStore? = nil,
        localSocketPath: String = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath,
        legacySocketDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".leo/state/leoterm", isDirectory: true),
        controlSocketDirectory: URL? = LeoControlSocketDirectory.default,
        controlSocketInstance: String = LeoHostSelection.defaultControlSocketInstance,
        controlSocketOwner: uid_t = geteuid(),
        connectionTarget: @escaping (LeoHostID, Int, LeoHostConnectionState) -> Void = { _, _, _ in }
    ) {
        self.store = store
        self.defaults = defaults
        self.runner = runner
        self.sshExecutable = sshExecutable
        self.transport = transport
        self.orphanStore = orphanStore ?? LeoTunnelOrphanStore(defaults: defaults)
        self.localSocketPath = localSocketPath
        self.legacySocketDirectory = legacySocketDirectory
        self.controlSocketDirectory = controlSocketDirectory ?? legacySocketDirectory
        self.controlSocketInstance = controlSocketInstance
        self.controlSocketOwner = controlSocketOwner
        self.connectionTarget = connectionTarget
        if let value = defaults.string(forKey: "leo.selectedHost"), value != "localhost" {
            selected = .remote(value)
        } else {
            selected = .local
        }
        state = .connected(socketPath: localSocketPath)
    }

    var legacyTooltip: String? { flavor == .legacy ? "leo 0.29+ required for remote hosts" : nil }

    /// Monotonic token bumped by every `select()`/`retry()`/`shutdown()`.
    /// Callers that capture a value, do async work, then want to know "did
    /// the selection move on while I was working" (e.g. `LeoAgentActions`
    /// dropping a stale completion) compare against this.
    var generationToken: Int { generation }

    /// The configuration backing the currently selected remote host, if any
    /// -- used by the UI for e.g. the "Open SSH" hint action.
    var selectedConfiguration: LeoHostConfiguration? {
        guard case .remote(let name) = selected else { return nil }
        return hosts.first { $0.name == name }
    }

    /// Reloads `hosts` from disk after the Hosts editor sheet saves. If the
    /// currently selected remote host was removed, falls back to localhost;
    /// if its configuration changed (any field), re-selects it (tearing
    /// down and reconnecting with the new settings); if unchanged, this is
    /// a no-op beyond refreshing `hosts` (so newly added/removed hosts still
    /// show up in the picker immediately).
    func reloadHostsAfterEdit() {
        guard case .remote(let name) = selected else {
            hosts = store.load()
            return
        }
        let previous = hosts.first { $0.name == name }
        hosts = store.load()
        guard let updated = hosts.first(where: { $0.name == name }) else {
            select(.local)
            return
        }
        if let previous, previous != updated {
            select(.remote(name))
        }
    }

    /// Builds a fresh `LeoHostsSheetModel` for the Hosts editor sheet, wired
    /// to reload this selection's hosts (and, if needed, re-select) once
    /// the sheet saves.
    func makeHostsSheetModel() -> LeoHostsSheetModel {
        LeoHostsSheetModel(store: store) { [weak self] in self?.reloadHostsAfterEdit() }
    }

    func start(flavor: LeoAPIFlavor) async {
        self.flavor = flavor
        hosts = store.load()
        select(selected)
    }

    /// Selects `host`. Localhost is published as `.connected` immediately.
    /// A remote host starts a fresh app-owned SSH tunnel connect attempt;
    /// any tunnel the previous selection was using is torn down (serialized
    /// through `retiring`, off the main actor). Never blocks the caller.
    func select(_ host: LeoHostID) {
        Self.logger.log("select host=\(host.displayName, privacy: .public) isShutDown=\(self.isShutDown) knownHosts=\(self.hosts.map(\.name), privacy: .public)")
        guard !isShutDown else { return }
        selected = host
        defaults.set(host.displayName, forKey: "leo.selectedHost")

        generation += 1
        let myGeneration = generation
        let barrier = beginTeardown()

        guard case .remote(let name) = host else {
            publish(.connected(socketPath: localSocketPath), host: host, generation: myGeneration)
            return
        }

        publish(.connecting, host: host, generation: myGeneration)
        guard let configuration = hosts.first(where: { $0.name == name }) else {
            publish(.failed(message: "Unknown host \(name)", hint: nil), host: host, generation: myGeneration)
            return
        }

        Task { [weak self] in
            await self?.connect(configuration: configuration, generation: myGeneration, barrier: barrier)
        }
    }

    /// Re-runs `select(selected)` -- there is no separate coalescing path;
    /// a retry is just a fresh, generation-guarded connect attempt that
    /// replaces whatever is currently in flight.
    func retry() { select(selected) }

    /// Synchronously (bounded) tears down the current tunnel. Called from
    /// the AppDelegate quit hook, which must not return until the child is
    /// confirmed gone. Bumps `generation` and sets `isShutDown` first so no
    /// pending connect (or a home-resolution SSH round trip already in
    /// flight) can launch a new tunnel after this returns.
    func shutdown() {
        generation += 1
        isShutDown = true
        let barrier = beginTeardown()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await barrier.value
            semaphore.signal()
        }
        let result = semaphore.wait(timeout: .now() + 3)
        // Only clear the orphan record once the tunnel's exit is CONFIRMED
        // (the barrier resolved within the bound): on a timeout the process
        // may still be alive, and clearing the record now would make the
        // NEXT launch's `reapAtLaunch` blind to it. `tunnel.onExit` (fired
        // whenever the process actually does exit, however late) clears it
        // independently either way.
        if result == .success, let record = currentOrphanRecord {
            orphanStore.clear(matching: record)
            currentOrphanRecord = nil
        }
    }

    /// Chains a new teardown onto whatever teardown is already in flight
    /// and returns it as the new barrier. Captures (and clears)
    /// `currentTunnel` itself so every caller -- `select()` and
    /// `shutdown()` alike -- goes through the exact same serialization.
    @discardableResult
    private func beginTeardown() -> Task<Void, Never> {
        let previousTunnel = currentTunnel
        currentTunnel = nil
        let awaited = retiring
        let barrier = Task.detached {
            await awaited?.value
            previousTunnel?.terminateAndWait()
        }
        retiring = barrier
        return barrier
    }

    private func connect(configuration: LeoHostConfiguration, generation myGeneration: Int, barrier: Task<Void, Never>) async {
        await barrier.value
        guard generation == myGeneration, !isShutDown else { return }

        var launchedTunnel: LeoTunnel?
        do {
            let remoteSocketPath = try await resolveRemoteSocketPath(configuration: configuration)
            let localPath = try prepareTunnelSocketPath(configuration: configuration)

            // A newer select()/retry()/shutdown() -- itself synchronous up to
            // this point -- may have raced ahead while the async work above
            // was in flight. Check again before touching the control socket
            // or ever constructing (let alone starting) a tunnel.
            guard generation == myGeneration, !isShutDown else { return }
            let arguments = try LeoSSHCommand(configuration: configuration).tunnelArguments(
                localSocketPath: localPath, remoteSocketPath: remoteSocketPath, controlPath: multiplexingControlPath(for: configuration)
            )

            let tunnel = LeoTunnel(
                executable: sshExecutable,
                arguments: arguments,
                localSocketPath: localPath,
                healthProbe: makeHealthProbe()
            )
            launchedTunnel = tunnel
            let orphanBox = LeoTunnelOrphanBox()
            let orphanStore = orphanStore
            // Recorded as soon as the process launches -- before any
            // (possibly long or gated) readiness probing -- so a crash
            // during probing still leaves an accurate reap record.
            tunnel.onLaunch = { [weak self] pid, startTime in
                let record = LeoTunnelOrphanRecord(pid: pid, startTime: startTime, socketPath: localPath)
                orphanBox.value = record
                orphanStore.record(record)
                Task { @MainActor in self?.currentOrphanRecord = record }
            }
            // `[weak tunnel]`: this closure is stored ON `tunnel.onExit`
            // itself: a strong capture of `tunnel` here would be a
            // self-referential retain cycle that keeps the tunnel (and its
            // `Process`) alive forever. If `tunnel` has already deallocated
            // by the time this fires, nothing else still references it
            // (i.e. it was already superseded), so there is nothing to do.
            tunnel.onExit = { [weak self, weak tunnel] exit in
                if let record = orphanBox.value { orphanStore.clear(matching: record) }
                Task { @MainActor in
                    guard let tunnel else { return }
                    self?.handleExit(exit, generation: myGeneration, tunnel: tunnel, configuration: configuration)
                }
            }
            currentTunnel = tunnel

            try await tunnel.start()

            // A newer selection may have superseded this tunnel while
            // `start()` was resolving, or `onExit` may already have fired
            // and published `.failed` in the narrow window between
            // readiness succeeding and this line running -- never let a
            // stale/dead tunnel overwrite that with `.connected`.
            guard generation == myGeneration, !isShutDown, currentTunnel === tunnel, !tunnel.hasExited else {
                if let record = orphanBox.value {
                    orphanStore.clear(matching: record)
                    if currentOrphanRecord?.pid == record.pid { currentOrphanRecord = nil }
                }
                await Task.detached { tunnel.terminateAndWait() }.value
                return
            }
            publish(.connected(socketPath: localPath), host: .remote(configuration.name), generation: myGeneration)
        } catch {
            Self.logger.error("connect failed host=\(configuration.name, privacy: .public) error=\(String(describing: error), privacy: .public)")
            if let launchedTunnel, currentTunnel === launchedTunnel { currentTunnel = nil }
            guard generation == myGeneration, !isShutDown else { return }
            let (message, hint) = Self.describe(error, configuration: configuration)
            publish(.failed(message: message, hint: hint), host: .remote(configuration.name), generation: myGeneration)
        }
    }

    /// Fires off-main from `LeoTunnel`; hops to main and only publishes if
    /// this is still the current generation AND the exiting tunnel is still
    /// the one currently tracked.
    private func handleExit(_ exit: LeoTunnelExit, generation myGeneration: Int, tunnel: LeoTunnel, configuration: LeoHostConfiguration) {
        if let record = currentOrphanRecord, record.pid == tunnel.pid { currentOrphanRecord = nil }
        guard generation == myGeneration, currentTunnel === tunnel else { return }
        currentTunnel = nil
        let message = exit.stderrTail.isEmpty ? "ssh exited (\(exit.status))" : exit.stderrTail
        publish(.failed(message: message, hint: Self.hint(forStderr: exit.stderrTail, target: configuration.sshTarget)), host: .remote(configuration.name), generation: myGeneration)
    }

    private func publish(_ newState: LeoHostConnectionState, host: LeoHostID, generation: Int) {
        state = newState
        Self.logger.log("publish host=\(host.displayName, privacy: .public) generation=\(generation) state=\(String(describing: newState), privacy: .public)")
        connectionTarget(host, generation, newState)
    }

    private func resolveRemoteSocketPath(configuration: LeoHostConfiguration) async throws -> String {
        let command = LeoSSHCommand(configuration: configuration)
        guard configuration.remoteSocketPath.hasPrefix("~/") else {
            return try command.resolvedRemoteSocketPath(home: "")
        }
        let arguments = try command.remoteHomeCommand()
        Self.logger.log("resolveRemoteSocketPath: running \(self.sshExecutable.path, privacy: .public) \(arguments.joined(separator: " "), privacy: .public)")
        let result = try await runner.run(executable: sshExecutable.path, arguments: arguments, timeout: 15)
        Self.logger.log("resolveRemoteSocketPath: status=\(result.status) stdout=\(String(data: result.stdout, encoding: .utf8) ?? "<non-utf8 \(result.stdout.count) bytes>", privacy: .public) stderr=\(String(data: result.stderr, encoding: .utf8) ?? "<non-utf8>", privacy: .public)")
        guard result.status == 0 else {
            throw LeoHostSelectionError.homeResolutionFailed(String(data: result.stderr, encoding: .utf8) ?? "")
        }
        let home = String(data: result.stdout, encoding: .utf8) ?? ""
        let resolved = try command.resolvedRemoteSocketPath(home: home)
        Self.logger.log("resolveRemoteSocketPath: home=\(home, privacy: .public) resolved=\(resolved, privacy: .public)")
        return resolved
    }

    /// The forwarded daemon socket grants full control of the remote leo
    /// daemon to whoever can connect to it, so it lives in the owner-only
    /// `controlSocketDirectory` (checked before every connect) and is never
    /// bound over another user's socket or anything that isn't a socket.
    /// A stale socket this app left at the pre-B-021 location is removed.
    private func prepareTunnelSocketPath(configuration: LeoHostConfiguration) throws -> String {
        do {
            try LeoControlSocketDirectory.prepare(controlSocketDirectory)
        } catch {
            Self.logger.error("tunnel socket directory not private path=\(self.controlSocketDirectory.path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw LeoHostSelectionError.unsafeSocketDirectory
        }
        let path = tunnelSocketPath(for: configuration)
        switch LeoControlSocket.inspect(path, owner: controlSocketOwner) {
        case .foreign: throw LeoHostSelectionError.foreignTunnelSocket
        case .notASocket: throw LeoHostSelectionError.occupiedTunnelSocketPath
        case .absent, .live, .stale, .unknown: break
        }
        removeStaleLegacySocket(for: configuration)
        return path
    }

    /// The forwarded daemon socket for `configuration`: in the owner-only
    /// `controlSocketDirectory` (short whatever the home directory; see
    /// `LeoControlSocketDirectory`), scoped to this app bundle.
    func tunnelSocketPath(for configuration: LeoHostConfiguration) -> String {
        controlSocketDirectory.appendingPathComponent(configuration.tunnelSocketFileName(instance: controlSocketInstance)).path
    }

    /// Unlinks only a socket this user owns that nobody listens on (never a
    /// file, a live socket or the directory itself), and never creates the
    /// old directory.
    private func removeStaleLegacySocket(for configuration: LeoHostConfiguration) {
        let path = legacySocketDirectory.appendingPathComponent(configuration.legacySocketFileName).path
        guard path != tunnelSocketPath(for: configuration) else { return }
        if LeoControlSocket.removeIfStale(path, owner: controlSocketOwner) == .stale {
            Self.logger.log("removed stale tunnel socket from the old location path=\(path, privacy: .public)")
        }
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
            stderrTail = error.localizedDescription
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
