#if DEBUG
import Combine
import Foundation
import LeoKit

/// DEBUG builds only: `LEO_MOVE_FIXTURE=1` replaces the machines with a
/// scripted pair (This Mac and `nas`) and their daemons with a fake, so the
/// move, copy and duplicate flows can be screenshotted without a real
/// daemon or real agents: a moved agent's dormant row, a move refused
/// mid-turn (`busy-agent`, until Force), and a duplicate that appears as a
/// new row once the "daemon" reports it.
@MainActor final class LeoMoveFixture {
    static let environmentKey = "LEO_MOVE_FIXTURE"
    private static let nas = LeoHostID.remote("nas")
    private static let movedAt = "2026-10-28T14:00:00Z"
    private static let firstGeneration = Int.max / 2

    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey] == "1"
    }

    private let model: LeoSidebarModel
    private var movedAway: [String: String] = ["old-agent": "nas"]
    private var onNAS: [String] = []
    private var copies: [String] = []
    private var generation = firstGeneration
    private var subscription: AnyCancellable?
    private(set) lazy var clients = LeoMoveFixtureClients(daemon: LeoMoveFixtureDaemon(world: self))

    init(model: LeoSidebarModel) {
        self.model = model
    }

    /// Fills the sidebar once This Mac's first snapshot has landed, as the
    /// machines fixture does, and again on every `refresh()`.
    func arm() {
        subscription = Publishers.CombineLatest(model.$machineOrder, model.$snapshots)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.model.snapshot(for: .local) != nil, !self.model.machineOrder.contains(Self.nas) else { return }
                self.refresh()
            }
    }

    /// The destinations a real daemon's `client.hosts` would give.
    func seedDestinations(into actions: LeoAgentActions) {
        actions.seedMoveDestinations(.hosts(["nas"]), for: .local)
        actions.seedMoveDestinations(.hosts([]), for: Self.nas)
    }

    func refresh() {
        generation += 1
        model.setMachines([.local, Self.nas])
        model.receive(snapshot(local, .local), for: .local)
        model.receive(snapshot(remote, Self.nas), for: Self.nas)
    }

    /// What the fake daemon did to `name`, as the next list will show it.
    func apply(_ request: LeoMoveRequest, to name: String) {
        switch (request.mode, request.to) {
        case (.move, let host?):
            movedAway[name] = host
            onNAS.append(name)
        case (.copy, let host?):
            if host == "nas" { onNAS.append(request.name ?? "\(name)-copy") }
        case (.copy, nil), (.move, nil):
            copies.append(request.name ?? "\(name)-copy")
        }
    }

    private var local: [LeoAgentRow] {
        let live = ["alpha", "busy-agent"].filter { movedAway[$0] == nil }
            .map { row($0, activity: $0 == "busy-agent" ? .working : .idle, action: $0 == "busy-agent" ? "Editing LeoSidebarView.swift" : nil) }
        let copied = copies.map { row($0) }
        let moved = movedAway.sorted { $0.key < $1.key }.map { name, host in
            row(name, status: .stopped, movedTo: host, movedAt: name == "old-agent" ? Self.movedAt : "2026-10-28T15:55:00Z")
        }
        return live + copied + moved
    }

    private var remote: [LeoAgentRow] { onNAS.map { row($0, host: Self.nas) } }

    private func snapshot(_ rows: [LeoAgentRow], _ host: LeoHostID) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: rows, connectivity: .connected, generation: generation, listRefreshSucceeded: true,
            features: LeoDaemonFeatures(["agent_move"]), featuresHost: host
        )
    }

    private func row(
        _ name: String, host: LeoHostID = .local, status: LeoAgentStatus = .running, activity: LeoActivity = .idle,
        action: String? = nil, movedTo: String? = nil, movedAt: String? = nil
    ) -> LeoAgentRow {
        LeoAgentRow(
            host: host, name: name, template: "claude", status: status, activity: activity, actionDetail: action,
            startedAt: "s", movedTo: movedTo, movedAt: movedAt
        )
    }
}

/// Both machines resolve to the one scripted daemon.
@MainActor final class LeoMoveFixtureClients: LeoMachineClientResolving {
    private let daemon: any LeoDaemonClient

    init(daemon: any LeoDaemonClient) { self.daemon = daemon }

    func daemon(for host: LeoHostID) -> (any LeoDaemonClient)? { daemon }
    func generation(for host: LeoHostID) -> Int { 1 }
    func configuration(for host: LeoHostID) -> LeoHostConfiguration? { nil }
}

/// A daemon whose moves finish at once, except `busy-agent`'s, which the
/// mid-turn check refuses until it is forced.
actor LeoMoveFixtureDaemon: LeoDaemonClient {
    private weak var world: LeoMoveFixture?
    private var jobs: [String: String] = [:]

    init(world: LeoMoveFixture) { self.world = world }

    func startMove(_ name: String, _ request: LeoMoveRequest) async throws -> LeoMoveJob {
        let isBusy = name == "busy-agent" && request.mode == .move && !request.force
        let id = "mv-\(jobs.count + 1)"
        let mode = request.mode.rawValue
        let to = request.to.map { #","to":"\#($0)""# } ?? ""
        let failure = #","error":{"code":"agent_busy","message":"agent is mid-turn; pass --force"}"#
        jobs[id] = #"{"id":"\#(id)","request":{"mode":"\#(mode)"\#(to)},"state":"\#(isBusy ? "failed" : "done")"\#(isBusy ? failure : "")}"#
        if !isBusy, let world { await MainActor.run { world.apply(request, to: name) } }
        return try Self.decode(#"{"id":"\#(id)","request":{"mode":"\#(mode)"\#(to)},"state":"running"}"#)
    }

    func moveJob(id: String) async throws -> LeoMoveJob {
        guard let json = jobs[id] else { throw LeoDaemonError.daemon(code: "not_found", message: "no such move job", matches: []) }
        return try Self.decode(json)
    }

    private static func decode(_ json: String) throws -> LeoMoveJob {
        try JSONDecoder().decode(LeoMoveJob.self, from: Data(json.utf8))
    }

    func listAgents() async throws -> [LeoAgent] { [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { throw LeoDaemonError.timeout }
    func start(_ name: String) async throws {}
    func stop(_ name: String, wakeOnMessage: Bool?) async throws {}
    func restart(_ name: String) async throws -> LeoAgent { throw LeoDaemonError.timeout }
    func reset(_ name: String) async throws {}
    func setTemplate(_ name: String, template: String) async throws {}
    func rename(_ name: String, newName: String) async throws -> LeoAgent { throw LeoDaemonError.timeout }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws {}
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { throw LeoDaemonError.timeout }
    func logs(_ name: String, lines: Int?) async throws -> String { "" }
}
#endif
