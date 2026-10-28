import Darwin
import Foundation
import OSLog
import LeoKit

/// The tunnel process a `LeoMachineConnection` drives: `LeoTunnel` in the
/// app, a scripted fake in tests.
protocol LeoTunnelProcess: AnyObject, Sendable {
    var onLaunch: (@Sendable (_ pid: Int32, _ startTime: TimeInterval) -> Void)? { get set }
    var onExit: (@Sendable (LeoTunnelExit) -> Void)? { get set }
    var pid: Int32? { get }
    var hasExited: Bool { get }
    func start() async throws
    func terminateAndWait()
}

extension LeoTunnel: LeoTunnelProcess {}

/// Everything needed to build one machine's tunnel.
struct LeoTunnelLaunch: Sendable {
    let host: LeoHostID
    let executable: URL
    let arguments: [String]
    let localSocketPath: String
    let healthProbe: @Sendable (String) async throws -> Bool
}

typealias LeoTunnelFactory = @Sendable (LeoTunnelLaunch) -> any LeoTunnelProcess

/// What every machine connection shares. The app builds exactly one: in
/// particular one `orphanStore`, since separate stores over the same
/// defaults key overwrite each other's records.
struct LeoMachineConnectionEnvironment {
    static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")
    static let defaultControlSocketInstance = LeoHostConfiguration.controlSocketInstance(
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "studio.blackpaw.leo"
    )
    static let realTunnel: LeoTunnelFactory = { launch in
        LeoTunnel(
            executable: launch.executable,
            arguments: launch.arguments,
            localSocketPath: launch.localSocketPath,
            healthProbe: launch.healthProbe
        )
    }

    let orphanStore: LeoTunnelOrphanStore
    let runner: any LeoProcessRunning
    let sshExecutable: URL
    let transport: any LeoDaemonTransport
    let localSocketPath: String
    /// `~/.leo/state/leoterm/`, where the forwarded socket lived before
    /// B-021. Only ever searched for this app's own stale sockets.
    let legacySocketDirectory: URL
    /// Holds the forwarded daemon sockets and the ControlMaster sockets;
    /// see `LeoControlSocketDirectory`.
    let controlSocketDirectory: URL
    /// Scopes socket names to this app bundle; see
    /// `LeoHostConfiguration.controlSocketFileName(instance:)`.
    let controlSocketInstance: String
    /// The only user whose sockets this app will use or remove; injectable
    /// because tests can't create another user's socket.
    let controlSocketOwner: uid_t
    let makeTunnel: LeoTunnelFactory

    init(
        orphanStore: LeoTunnelOrphanStore,
        runner: any LeoProcessRunning = LeoProcessRunner(),
        sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        transport: any LeoDaemonTransport = LeoUnixSocketTransport(),
        localSocketPath: String = LeoLocalDaemon.socketPath,
        legacySocketDirectory: URL = LeoTunnelOrphanStore.defaultLegacySocketDirectory,
        controlSocketDirectory: URL? = LeoControlSocketDirectory.default,
        controlSocketInstance: String = LeoMachineConnectionEnvironment.defaultControlSocketInstance,
        controlSocketOwner: uid_t = geteuid(),
        makeTunnel: @escaping LeoTunnelFactory = LeoMachineConnectionEnvironment.realTunnel
    ) {
        self.orphanStore = orphanStore
        self.runner = runner
        self.sshExecutable = sshExecutable
        self.transport = transport
        self.localSocketPath = localSocketPath
        self.legacySocketDirectory = legacySocketDirectory
        self.controlSocketDirectory = controlSocketDirectory ?? legacySocketDirectory
        self.controlSocketInstance = controlSocketInstance
        self.controlSocketOwner = controlSocketOwner
        self.makeTunnel = makeTunnel
    }

    /// The forwarded daemon socket for `configuration`: in the owner-only
    /// `controlSocketDirectory`, scoped to this app bundle.
    func tunnelSocketPath(for configuration: LeoHostConfiguration) -> String {
        controlSocketDirectory.appendingPathComponent(configuration.tunnelSocketFileName(instance: controlSocketInstance)).path
    }

    /// The tunnel's ControlMaster socket for `configuration`. SFTP sessions
    /// for the machine multiplex over it.
    func controlPath(for configuration: LeoHostConfiguration) -> String {
        controlSocketDirectory.appendingPathComponent(configuration.controlSocketFileName(instance: controlSocketInstance)).path
    }

    /// The remote daemon socket, with a leading `~/` resolved by one ssh
    /// round trip to the machine.
    func resolveRemoteSocketPath(for configuration: LeoHostConfiguration) async throws -> String {
        let command = LeoSSHCommand(configuration: configuration)
        guard configuration.remoteSocketPath.hasPrefix("~/") else {
            return try command.resolvedRemoteSocketPath(home: "")
        }
        let result = try await runner.run(executable: sshExecutable.path, arguments: try command.remoteHomeCommand(), timeout: 15)
        guard result.status == 0 else {
            throw LeoHostSelectionError.homeResolutionFailed(String(data: result.stderr, encoding: .utf8) ?? "")
        }
        return try command.resolvedRemoteSocketPath(home: String(data: result.stdout, encoding: .utf8) ?? "")
    }

    /// The forwarded daemon socket grants full control of the remote leo
    /// daemon to whoever can connect to it, so it lives in the owner-only
    /// `controlSocketDirectory` (checked before every connect) and is never
    /// bound over another user's socket or anything that isn't a socket.
    /// A stale socket this app left at the pre-B-021 location is removed.
    func prepareTunnelSocketPath(for configuration: LeoHostConfiguration) throws -> String {
        do {
            try LeoControlSocketDirectory.prepare(controlSocketDirectory)
        } catch {
            Self.logger.error("tunnel socket directory not private path=\(controlSocketDirectory.path, privacy: .public) error=\(String(describing: error), privacy: .public)")
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

    /// The control path the tunnel should listen on, or nil to run it
    /// without a master: when ssh can't use the path, when the directory
    /// isn't provably private, or when something other than a socket -- or
    /// another user's socket -- occupies it. A socket a dead master left
    /// behind is removed first, since `ControlMaster=yes` would otherwise run
    /// without multiplexing rather than replace it. A live socket is left
    /// alone. Called only after the previous tunnel's teardown has resolved.
    func multiplexingControlPath(for configuration: LeoHostConfiguration) -> String? {
        let path = controlPath(for: configuration)
        guard LeoSSHCommand.isValidControlPath(path) else {
            Self.logger.error("control path unsupported by ssh; tunnel runs without file access path=\(path, privacy: .public)")
            return nil
        }
        do {
            try LeoControlSocketDirectory.prepare(controlSocketDirectory)
        } catch {
            Self.logger.error("control directory not private; tunnel runs without file access path=\(path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
        switch LeoControlSocket.removeIfStale(path, owner: controlSocketOwner) {
        case .absent, .stale, .live:
            return path
        case .notASocket, .foreign:
            Self.logger.error("control path occupied; tunnel runs without file access path=\(path, privacy: .public)")
            return nil
        case .unknown(let code):
            Self.logger.error("control socket check failed; leaving it path=\(path, privacy: .public) errno=\(code)")
            return path
        }
    }

    func makeHealthProbe() -> @Sendable (String) async throws -> Bool {
        let transport = transport
        return { path in
            let response = try await transport.send(LeoHTTPRequest(method: "GET", path: "/health"), socketPath: path, timeout: 1)
            return response.status == 200
        }
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
}
