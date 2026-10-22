#if DEBUG
import Combine
import Foundation
import LeoKit

/// DEBUG builds only: `LEO_MACHINES_FIXTURE=1` fills the sidebar with
/// several machines -- healthy, warning, offline and no-stats -- once This
/// Mac's first snapshot has landed (connected or not, so an isolated
/// launch with no daemon works), so every header state can be screenshotted
/// without remote machines. The machines are display-only: their numbers
/// stay put (no poller reads them) and nothing connects to them.
enum LeoMachinesFixture {
    static let environmentKey = "LEO_MACHINES_FIXTURE"
    private static let generation = Int.max / 2
    private static let gb: Int64 = 1_073_741_824

    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey] == "1"
    }

    /// Fills `model` once This Mac has delivered a snapshot, and again
    /// whenever the runtime resets the machines (it does, as the registry
    /// starts). The returned object holds the subscription; release it to
    /// disarm.
    @MainActor static func arm(model: LeoSidebarModel, now: @escaping () -> Date = Date.init) -> AnyObject {
        Arming(model: model, now: now)
    }

    @MainActor private final class Arming {
        private var subscription: AnyCancellable?

        init(model: LeoSidebarModel, now: @escaping () -> Date) {
            // `@Published` emits before it stores: hop, then read the model.
            subscription = Publishers.CombineLatest(model.$machineOrder, model.$snapshots)
                .receive(on: DispatchQueue.main)
                .sink { [weak model] _ in
                    guard let model, model.snapshot(for: .local) != nil,
                          !model.machineOrder.contains(LeoMachinesFixture.hosts[0]) else { return }
                    LeoMachinesFixture.fill(model, now: now())
                }
        }
    }

    private static let hosts: [LeoHostID] = [.remote("Dionysus"), .remote("Hestia"), .remote("leo-vm")]

    @MainActor static func fill(_ model: LeoSidebarModel, now: Date) {
        let (dionysus, hestia, vm) = (hosts[0], hosts[1], hosts[2])
        model.setMachines([.local] + hosts)
        let stats = LeoDaemonFeatures(["machine_stats"])
        model.receive(
            snapshot([
                row(.local, "leoterm", attention: .needsInput, action: "Run: git push origin feat/machines"),
                row(.local, "web", attention: .working, action: "Editing LeoSidebarView.swift"),
            ], attention: 1, features: stats, host: .local), for: .local
        )
        model.receive(
            snapshot([
                row(dionysus, "swift-test", attention: .working, action: "Running swift test"),
            ], features: stats, host: dionysus), for: dionysus
        )
        model.receive(
            snapshot([row(hestia, "backup-check")], connectivity: .failed(message: "ssh: connect to host hestia.lan port 22: Operation timed out"), host: hestia),
            for: hestia
        )
        model.receive(
            snapshot([
                row(vm, "e2e-runner", attention: .working, action: "Tart VM boot check"),
                row(vm, "build-check", attention: .errored, action: "xcodebuild exited with status 65"),
            ], attention: 1, host: vm), for: vm
        )
        model.receiveStats(sample(now, cpu: 23, memory: 0.31, disk: 0.41, memoryTotal: 16), for: .local)
        model.receiveStats(sample(now.addingTimeInterval(-3), cpu: 41, memory: 0.85, disk: 0.47, memoryTotal: 32), for: dionysus)
        model.receiveStats(nil, for: vm)
    }

    private static func sample(_ at: Date, cpu: Double, memory: Double, disk: Double, memoryTotal: Int64) -> LeoMachineStats {
        LeoMachineStats(
            sampledAt: at, cpu: .init(percent: cpu, cores: 8),
            memory: .init(usedBytes: Int64(Double(memoryTotal * gb) * memory), totalBytes: memoryTotal * gb),
            disk: .init(path: "/Users/evan/.leo/state", usedBytes: Int64(Double(994 * gb) * disk), totalBytes: 994 * gb)
        )
    }

    private static func snapshot(
        _ rows: [LeoAgentRow], connectivity: LeoConnectivity = .connected, attention: Int = 0,
        features: LeoDaemonFeatures = .none, host: LeoHostID
    ) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: rows, connectivity: connectivity, generation: generation, listRefreshSucceeded: true,
            attentionCount: attention, features: features, featuresHost: host
        )
    }

    private static func row(
        _ host: LeoHostID, _ name: String, status: LeoAgentStatus = .running, attention: LeoAttentionBadge? = nil, action: String? = nil
    ) -> LeoAgentRow {
        LeoAgentRow(
            host: host, name: name, template: nil, status: status, activity: .idle, actionDetail: action,
            attention: attention, startedAt: "s"
        )
    }
}
#endif
