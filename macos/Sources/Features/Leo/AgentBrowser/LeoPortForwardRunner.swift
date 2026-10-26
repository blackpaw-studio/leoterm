import Foundation
import LeoKit
import OSLog

/// Opens and closes one local→remote port forward on a machine's ssh
/// connection. `LeoMuxForwardRunner` rides the tunnel's ControlMaster;
/// `LeoProcessForwardRunner` spawns one `ssh -N -L` per forward when there
/// is no master.
protocol LeoPortForwardRunning: Sendable {
    /// Throws `.portBusy` when `local` can't be bound.
    func open(local: Int, remotePort: Int) async throws
    func close(local: Int, remotePort: Int) async
    /// False once the forward is known to be gone (its process exited).
    func isOpen(local: Int) -> Bool
}

/// ssh's wording when a listener can't bind on a machine without IPv6
/// loopback; any other 255 is a busy port.
private func isIPv6Unavailable(_ stderr: String) -> Bool {
    let text = stderr.lowercased()
    return text.contains("cannot assign requested address") || text.contains("address family not supported")
}

/// `ssh -O forward` / `-O cancel` against the tunnel's ControlMaster, once
/// per loopback address. Forwards die with the master, so `isOpen` has
/// nothing to track.
final class LeoMuxForwardRunner: LeoPortForwardRunning, @unchecked Sendable {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")
    private static let timeout: TimeInterval = 15
    private static let busyStatus: Int32 = 255

    private let command: LeoSSHCommand
    private let controlPath: String
    private let runner: any LeoProcessRunning
    private let sshExecutable: URL
    private let prober: any LeoPortProbing
    private let lock = NSLock()
    /// Local port → the addresses `open` actually forwarded, for `close`.
    private var opened: [Int: [LeoLoopbackAddress]] = [:]

    init(command: LeoSSHCommand, controlPath: String, runner: any LeoProcessRunning, sshExecutable: URL, prober: any LeoPortProbing) {
        self.command = command
        self.controlPath = controlPath
        self.runner = runner
        self.sshExecutable = sshExecutable
        self.prober = prober
    }

    func open(local: Int, remotePort: Int) async throws {
        // IPv4 first: a busy port fails here with nothing to undo.
        _ = try await forward(.ipv4, local: local, remotePort: remotePort)
        var forwarded: [LeoLoopbackAddress] = [.ipv4]
        if prober.isIPv6LoopbackAvailable() {
            do {
                if try await forward(.ipv6, local: local, remotePort: remotePort) { forwarded.append(.ipv6) }
            } catch {
                await cancel(.ipv4, local: local, remotePort: remotePort)
                throw error
            }
        } else {
            Self.logger.log("no IPv6 loopback; forward is IPv4-only local=\(local) remote=\(remotePort)")
        }
        lock.withLock { opened[local] = forwarded }
    }

    func close(local: Int, remotePort: Int) async {
        let addresses = lock.withLock { opened.removeValue(forKey: local) } ?? [.ipv4]
        for address in addresses {
            await cancel(address, local: local, remotePort: remotePort)
        }
    }

    func isOpen(local _: Int) -> Bool { true }

    /// False only when `address` is IPv6 and the machine can't bind it: the
    /// caller keeps the IPv4 forward and logs. A busy port throws `.portBusy`.
    private func forward(_ address: LeoLoopbackAddress, local: Int, remotePort: Int) async throws -> Bool {
        let result = try await run(address, local: local, remotePort: remotePort, op: .forward)
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        switch result.status {
        case 0:
            return true
        case Self.busyStatus where address == .ipv6 && isIPv6Unavailable(stderr):
            Self.logger.log("IPv6 loopback listener failed; forward is IPv4-only local=\(local) remote=\(remotePort)")
            return false
        case Self.busyStatus:
            throw LeoPortForwardError.portBusy
        default:
            throw LeoPortForwardError.failed(stderr)
        }
    }

    private func cancel(_ address: LeoLoopbackAddress, local: Int, remotePort: Int) async {
        do {
            let result = try await run(address, local: local, remotePort: remotePort, op: .cancel)
            if result.status != 0 {
                Self.logger.error("forward cancel failed local=\(local) remote=\(remotePort) status=\(result.status)")
            }
        } catch {
            Self.logger.error("forward cancel failed local=\(local) remote=\(remotePort) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func run(_ address: LeoLoopbackAddress, local: Int, remotePort: Int, op: LeoForwardOperation) async throws -> LeoProcessResult {
        let arguments: [String]
        do {
            arguments = try command.forwardArguments(controlPath: controlPath, local: local, remotePort: remotePort, op: op, address: address)
        } catch {
            throw LeoPortForwardError.failed(String(describing: error))
        }
        do {
            return try await runner.run(executable: sshExecutable.path, arguments: arguments, timeout: Self.timeout)
        } catch {
            throw LeoPortForwardError.failed(String(describing: error))
        }
    }
}

/// One `ssh -N -L` process per forward, built on the tunnel's process
/// lifecycle (`LeoTunnelFactory`): readiness is the forwarded port accepting
/// connections, and a dead process makes `isOpen` false.
final class LeoProcessForwardRunner: LeoPortForwardRunning, @unchecked Sendable {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")
    private static let busyStatus: Int32 = 255

    private let host: LeoHostID
    private let command: LeoSSHCommand
    private let sshExecutable: URL
    private let prober: any LeoPortProbing
    private let makeTunnel: LeoTunnelFactory
    private let lock = NSLock()
    private var processes: [Int: any LeoTunnelProcess] = [:]

    init(
        host: LeoHostID,
        command: LeoSSHCommand,
        sshExecutable: URL,
        prober: any LeoPortProbing,
        makeTunnel: @escaping LeoTunnelFactory = LeoMachineConnectionEnvironment.realTunnel
    ) {
        self.host = host
        self.command = command
        self.sshExecutable = sshExecutable
        self.prober = prober
        self.makeTunnel = makeTunnel
    }

    func open(local: Int, remotePort: Int) async throws {
        guard prober.isIPv6LoopbackAvailable() else {
            Self.logger.log("no IPv6 loopback; forward is IPv4-only local=\(local) remote=\(remotePort)")
            return try await launch(local: local, remotePort: remotePort, addresses: [.ipv4])
        }
        do {
            try await launch(local: local, remotePort: remotePort, addresses: [.ipv4, .ipv6])
        } catch LeoPortForwardError.ipv6Unavailable {
            Self.logger.log("IPv6 loopback listener failed; forward is IPv4-only local=\(local) remote=\(remotePort)")
            try await launch(local: local, remotePort: remotePort, addresses: [.ipv4])
        }
    }

    private func launch(local: Int, remotePort: Int, addresses: [LeoLoopbackAddress]) async throws {
        let arguments: [String]
        do {
            arguments = try command.forwardProcessArguments(local: local, remotePort: remotePort, addresses: addresses)
        } catch {
            throw LeoPortForwardError.failed(String(describing: error))
        }
        let prober = prober
        // `LeoTunnel` treats `localSocketPath` as an opaque readiness token
        // (and unlinks it if a file sits there); a host:port string never
        // names a file. IPv4 accepting is the readiness signal: ssh binds
        // every listener before it serves any.
        let process = makeTunnel(LeoTunnelLaunch(
            host: host,
            executable: sshExecutable,
            arguments: arguments,
            localSocketPath: "127.0.0.1:\(local)",
            healthProbe: { _ in prober.isListening(local) }
        ))
        do {
            try await process.start()
        } catch LeoTunnelError.exitedBeforeReady(let status, let stderrTail) {
            if addresses.contains(.ipv6), isIPv6Unavailable(stderrTail) { throw LeoPortForwardError.ipv6Unavailable }
            throw status == Self.busyStatus ? LeoPortForwardError.portBusy : .failed(stderrTail)
        } catch LeoTunnelError.notReady(let stderrTail) {
            throw LeoPortForwardError.failed(stderrTail)
        } catch {
            throw LeoPortForwardError.failed(String(describing: error))
        }
        lock.withLock { processes[local] = process }
    }

    func close(local: Int, remotePort _: Int) async {
        guard let process = lock.withLock({ processes.removeValue(forKey: local) }) else { return }
        // terminateAndWait blocks up to a second; keep it off the caller's actor.
        await Task.detached { process.terminateAndWait() }.value
    }

    func isOpen(local: Int) -> Bool {
        lock.withLock { processes[local].map { !$0.hasExited } ?? false }
    }
}
