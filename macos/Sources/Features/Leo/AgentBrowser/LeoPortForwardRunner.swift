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

/// `ssh -O forward` / `-O cancel` against the tunnel's ControlMaster.
/// Forwards die with the master, so `isOpen` has nothing to track.
struct LeoMuxForwardRunner: LeoPortForwardRunning {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")
    private static let timeout: TimeInterval = 15
    private static let busyStatus: Int32 = 255

    let command: LeoSSHCommand
    let controlPath: String
    let runner: any LeoProcessRunning
    let sshExecutable: URL

    func open(local: Int, remotePort: Int) async throws {
        let result = try await run(local: local, remotePort: remotePort, op: .forward)
        switch result.status {
        case 0: return
        case Self.busyStatus: throw LeoPortForwardError.portBusy
        default: throw LeoPortForwardError.failed(String(decoding: result.stderr, as: UTF8.self))
        }
    }

    func close(local: Int, remotePort: Int) async {
        do {
            let result = try await run(local: local, remotePort: remotePort, op: .cancel)
            if result.status != 0 {
                Self.logger.error("forward cancel failed local=\(local) remote=\(remotePort) status=\(result.status)")
            }
        } catch {
            Self.logger.error("forward cancel failed local=\(local) remote=\(remotePort) error=\(String(describing: error), privacy: .public)")
        }
    }

    func isOpen(local _: Int) -> Bool { true }

    private func run(local: Int, remotePort: Int, op: LeoForwardOperation) async throws -> LeoProcessResult {
        let arguments: [String]
        do {
            arguments = try command.forwardArguments(controlPath: controlPath, local: local, remotePort: remotePort, op: op)
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
        let arguments: [String]
        do {
            arguments = try command.forwardProcessArguments(local: local, remotePort: remotePort)
        } catch {
            throw LeoPortForwardError.failed(String(describing: error))
        }
        let prober = prober
        // `LeoTunnel` treats `localSocketPath` as an opaque readiness token
        // (and unlinks it if a file sits there); a host:port string never
        // names a file.
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
