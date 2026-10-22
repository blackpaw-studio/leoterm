import Foundation
import LeoKit

/// Test Connection: ssh, then a throwaway `LeoMachineConnection` (its
/// tunnel's `/health` probe), the daemon's `/version`, and one bounded read
/// of the `/events` hello, the only place `machine_stats` is advertised.
///
/// The throwaway connection gets a fresh configuration id, and with it its
/// own forwarded and ControlMaster sockets, so it never touches the live
/// connection of the machine under test. It is torn down before the report
/// returns, whatever the outcome.
@MainActor final class LeoMachineConnectionTester: LeoMachineConnectionTesting {
    static let sshTimeout: TimeInterval = 15

    private let environment: LeoMachineConnectionEnvironment
    private let activityTransport: any LeoSocketActivityTransport
    private let connectTimeout: Duration
    private let helloTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> TimeInterval

    init(
        environment: LeoMachineConnectionEnvironment,
        activityTransport: any LeoSocketActivityTransport = LeoUnixSocketTransport(),
        connectTimeout: Duration = .seconds(20),
        helloTimeout: Duration = .seconds(3),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.environment = environment
        self.activityTransport = activityTransport
        self.connectTimeout = connectTimeout
        self.helloTimeout = helloTimeout
        self.sleep = sleep
        self.now = now
    }

    func test(_ configuration: LeoHostConfiguration) async -> LeoConnectionTestReport {
        let started = now()
        let probe = Self.throwaway(from: configuration)
        let sshDetail: String
        switch await checkSSH(probe) {
        case .failure(let failure): return .sshFailed(failure.detail, duration: now() - started)
        case .success(let detail): sshDetail = detail
        }
        return await checkDaemon(probe, sshDetail: sshDetail, started: started)
    }

    /// The same machine under a new id, so every socket name is new.
    private static func throwaway(from configuration: LeoHostConfiguration) -> LeoHostConfiguration {
        LeoHostConfiguration(
            name: configuration.name, sshTarget: configuration.sshTarget, identityFile: configuration.identityFile,
            remoteLeoPath: configuration.remoteLeoPath, remoteSocketPath: configuration.remoteSocketPath
        )
    }

    // MARK: SSH

    private func checkSSH(_ probe: LeoHostConfiguration) async -> Result<String, StepFailure> {
        do {
            let arguments = try LeoSSHCommand(configuration: probe).remoteHomeCommand()
            let result = try await environment.runner.run(
                executable: environment.sshExecutable.path, arguments: arguments, timeout: Self.sshTimeout
            )
            guard result.status == 0 else {
                let stderr = String(bytes: result.stderr, encoding: .utf8) ?? ""
                let line = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "ssh exited (\(result.status))"
                return .failure(StepFailure(LeoSFTPServerText.isolated(line)))
            }
            let user = probe.user.map { " as \($0)" } ?? ""
            return .success("\(probe.host) reachable\(user)")
        } catch {
            return .failure(StepFailure(LeoSFTPServerText.isolated(error.localizedDescription)))
        }
    }

    // MARK: Daemon

    private func checkDaemon(_ probe: LeoHostConfiguration, sshDetail: String, started: TimeInterval) async -> LeoConnectionTestReport {
        var generation = 0
        let (states, publish) = AsyncStream.makeStream(of: LeoHostConnectionState.self)
        let connection = LeoMachineConnection(
            target: .remote(probe),
            environment: environment,
            nextGeneration: { generation += 1; return generation },
            onState: { _, state in publish.yield(state) }
        )
        connection.connect()
        let report = await daemonReport(connection, states: states, sshDetail: sshDetail, started: started, probe: probe)
        publish.finish()
        let barrier = connection.shutdown()
        await barrier.value
        connection.clearOrphanRecord()
        return report
    }

    private func daemonReport(
        _ connection: LeoMachineConnection, states: AsyncStream<LeoHostConnectionState>,
        sshDetail: String, started: TimeInterval, probe: LeoHostConfiguration
    ) async -> LeoConnectionTestReport {
        func failed(_ detail: String) -> LeoConnectionTestReport {
            .daemonFailed(sshDetail: sshDetail, detail: detail, duration: now() - started)
        }
        let settled = await first(within: connectTimeout) { await Self.firstSettled(in: states) }
        switch settled {
        case nil:
            return failed("Timed out waiting for the daemon")
        case .failed(let message, let hint)?:
            let text = LeoSFTPServerText.isolated(message)
            return failed(hint.map { "\(text). \(LeoSFTPServerText.isolated($0))" } ?? text)
        case .connecting?:
            return failed("Timed out waiting for the daemon")
        case .connected(let socketPath)?:
            let client = LeoSocketDaemonClient(socketPath: socketPath, transport: environment.transport)
            let version: String
            do {
                version = try await client.version()
            } catch {
                return failed("The daemon didn't answer /version: " + LeoSFTPServerText.isolated(error.localizedDescription))
            }
            let features = await readHelloFeatures(socketPath: socketPath)
            return LeoConnectionTestReport(
                outcomes: [
                    .ssh: .passed(sshDetail),
                    .daemon: .passed("leo \(version) answered"),
                    .machineStats: Self.statsOutcome(features),
                ],
                duration: now() - started
            )
        }
    }

    private static func firstSettled(in states: AsyncStream<LeoHostConnectionState>) async -> LeoHostConnectionState? {
        for await state in states {
            switch state {
            case .connecting: continue
            case .connected, .failed: return state
            }
        }
        return nil
    }

    // MARK: Machine stats

    private func readHelloFeatures(socketPath: String) async -> [String]? {
        let client = LeoSocketActivityClient(socketPath: socketPath, transport: activityTransport)
        return await first(within: helloTimeout) {
            for await event in await client.events() {
                switch event {
                case .hello(_, _, _, _, _, let features): return features
                case .disconnected: return nil
                default: continue
                }
            }
            return nil
        }
    }

    private static func statsOutcome(_ features: [String]?) -> LeoConnectionTestOutcome {
        guard let features else { return .unavailable("The daemon sent no hello") }
        guard LeoDaemonFeatures(features).contains(.machineStats) else {
            return .unavailable("Not offered by this daemon (needs leo 0.57 or newer)")
        }
        return .passed("Available (machine_stats)")
    }

    // MARK: Helpers

    private struct StepFailure: Error {
        let detail: String
        init(_ detail: String) { self.detail = detail }
    }

    /// `work`'s result, or nil when it finishes empty-handed or `timeout`
    /// passes first. The loser is cancelled.
    private func first<T: Sendable>(within timeout: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
        let sleep = sleep
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await sleep(timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
