#if DEBUG
import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// Four scripted machines for screenshots (`-machinesFixture`): two healthy
/// with stats, one unreachable, one on a daemon too old for stats. Pair it
/// with `-statsStyle capsules|bars|rings|numbers|off`. No daemon is needed.
enum MachinesFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-machinesFixture") }

    private static func daemon(_ name: String, _ host: String) -> PairedDaemon {
        PairedDaemon(
            id: "fixture-\(name)", name: name, baseURL: URL(string: "https://\(host)")!, urls: [],
            deviceID: "fixture-device", pairedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static let daemons = [
        daemon("MacBook Pro", "evans-mbp.local"), daemon("Dionysus", "dionysus.lan"),
        daemon("Hestia", "hestia.lan"), daemon("leo-vm", "192.168.64.7"),
    ]

    private static func agents(_ count: Int) -> LeoObservedState {
        LeoObservedState(agents: (0..<count).map {
            LeoObservedAgent(name: "agent-\($0)", status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil, attention: nil, startedAt: nil, template: "coding", harness: "claude")
        })
    }

    private static func stats(cpu: Double, memory: Double, disk: Double) -> LeoMachineStats {
        LeoMachineStats(
            sampledAt: Date(), cpu: .init(percent: cpu, cores: 8),
            memory: .init(usedBytes: Int64(memory * 1_000), totalBytes: 1_000),
            disk: .init(path: "/", usedBytes: Int64(disk * 1_000), totalBytes: 1_000)
        )
    }

    /// Replaces the paired daemons, keychain and daemon transport.
    static func prepare(_ values: inout DependencyValues) {
        values.pairedDaemons.load = { daemons }
        values.pairedDaemons.save = { _ in }
        values.secrets.load = { _ in DaemonSecrets(token: "fixture") }
        values.daemonClient.events = { connection in
            AsyncThrowingStream { continuation in
                switch connection.daemonID {
                case "fixture-Hestia":
                    continuation.finish(throwing: LeoDaemonError.transport("Operation timed out"))
                case "fixture-leo-vm":
                    continuation.yield(.hello(seq: 1, at: nil, version: "0.36.0", serverTime: nil))
                default:
                    continuation.yield(.hello(seq: 1, at: nil, version: "0.57.0", serverTime: nil, features: ["machine_stats"]))
                }
            }
        }
        values.daemonClient.fetchState = { connection in
            agents(connection.daemonID == "fixture-leo-vm" ? 2 : 3)
        }
        values.daemonClient.machineStats = { connection in
            connection.daemonID == "fixture-Dionysus"
                ? stats(cpu: 23, memory: 0.85, disk: 0.47)
                : stats(cpu: 41, memory: 0.58, disk: 0.64)
        }
    }

    /// Opens the Machines screen once the app has launched.
    @MainActor static func openMachines(_ store: StoreOf<AppFeature>) {
        store.send(.tabSelected(.machines))
    }
}
#endif
