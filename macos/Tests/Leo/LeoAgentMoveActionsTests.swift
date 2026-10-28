import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-324: move, copy and duplicate through `LeoAgentActions`.
@MainActor struct LeoAgentMoveActionsTests {
    private let row = LeoAgentRow(host: .local, name: "alpha", template: "default", status: .running, activity: .unknown, actionDetail: nil)

    private func makeActions(
        _ daemon: MoveDaemon, model: LeoSidebarModel? = nil, refreshes: RefreshCounter? = nil, clients: FakeMachineClients? = nil
    ) -> LeoAgentActions {
        LeoAgentActions(
            clients: clients ?? FakeMachineClients(daemon: daemon), cli: .recordingForTests(templates: []), model: model ?? LeoSidebarModel(),
            processRunner: LeoRecordingTemplateRunner(), moveSleep: { _ in }, refresh: { refreshes?.count += 1 }
        )
    }

    private static func job(_ state: String, mode: String = "move", extra: String = "") -> LeoMoveJob {
        let json = #"{"id":"mv-1","request":{"mode":"\#(mode)","to":"nas"},"state":"\#(state)"\#(extra)}"#
        guard let job = try? JSONDecoder().decode(LeoMoveJob.self, from: Data(json.utf8)) else { fatalError("bad fixture") }
        return job
    }

    private static let busy = #","error":{"code":"agent_busy","message":"pass --force"}"#

    @Test func eachCallSendsItsExactRequest() async {
        let daemon = MoveDaemon(polls: Array(repeating: Self.job("done", extra: #","result":{"name":"alpha"}"#), count: 3))
        let actions = makeActions(daemon)
        actions.move(row, to: "nas")
        await awaitCondition { await daemon.requests.count == 1 }
        await awaitCondition { await MainActor.run { !actions.pendingActions.contains(row.id) } }
        actions.copy(row, to: "nas", name: "fork")
        await awaitCondition { await daemon.requests.count == 2 }
        await awaitCondition { await MainActor.run { !actions.pendingActions.contains(row.id) } }
        actions.duplicate(row, name: nil)
        await awaitCondition { await daemon.requests.count == 3 }
        #expect(await daemon.requests == [
            .init(name: "alpha", request: .move(to: "nas")),
            .init(name: "alpha", request: .copy(to: "nas", name: "fork")),
            .init(name: "alpha", request: .duplicate()),
        ])
    }

    @Test func aFinishedMoveRefreshesOnce() async {
        let refreshes = RefreshCounter()
        let daemon = MoveDaemon(polls: [Self.job("running"), Self.job("done", extra: #","result":{"name":"alpha"}"#)])
        let actions = makeActions(daemon, refreshes: refreshes)
        actions.move(row, to: "nas")
        await awaitCondition { await MainActor.run { refreshes.count == 1 } }
        #expect(actions.forceOffer == nil)
        #expect(await daemon.pollCount == 2)
    }

    @Test func aBusyMovePublishesTheForceOfferWithTheAppWording() async {
        let model = LeoSidebarModel()
        let daemon = MoveDaemon(polls: [Self.job("failed", extra: Self.busy)])
        let actions = makeActions(daemon, model: model)
        actions.move(row, to: "nas")
        await awaitCondition { await MainActor.run { actions.forceOffer != nil } }
        #expect(actions.forceOffer == LeoMoveForceOffer(row: row, destination: "nas", message: "This agent is in the middle of a turn."))
        #expect(model.rowErrors[row.id] == nil, "the offer replaces the row error")
    }

    @Test func acceptingTheOfferResendsWithForce() async {
        let daemon = MoveDaemon(polls: [Self.job("failed", extra: Self.busy), Self.job("done", extra: #","result":{"name":"alpha"}"#)])
        let actions = makeActions(daemon)
        actions.move(row, to: "nas")
        await awaitCondition { await MainActor.run { actions.forceOffer != nil } }
        await awaitCondition { await MainActor.run { !actions.pendingActions.contains(row.id) } }
        actions.acceptForceOffer()
        await awaitCondition { await daemon.requests.count == 2 }
        #expect(await daemon.requests.last?.request == .move(to: "nas", force: true))
        #expect(actions.forceOffer == nil)
    }

    @Test func dismissingTheOfferSendsNothing() async {
        let daemon = MoveDaemon(polls: [Self.job("failed", extra: Self.busy)])
        let actions = makeActions(daemon)
        actions.move(row, to: "nas")
        await awaitCondition { await MainActor.run { actions.forceOffer != nil } }
        actions.dismissForceOffer()
        #expect(actions.forceOffer == nil)
        #expect(await daemon.requests.count == 1)
    }

    @Test func aBusyCopyShowsTheErrorAndOffersNoForce() async {
        let model = LeoSidebarModel()
        let daemon = MoveDaemon(polls: [Self.job("failed", mode: "copy", extra: Self.busy)])
        let actions = makeActions(daemon, model: model)
        actions.copy(row, to: "nas", name: nil)
        await awaitCondition { await MainActor.run { model.rowErrors[row.id] != nil } }
        #expect(actions.forceOffer == nil)
        #expect(model.rowErrors[row.id] == "pass --force", "a copy's busy text is the daemon's own")
        #expect(model.rowErrorCodes[row.id] == "agent_busy")
    }

    @Test func aSynchronousRefusalShowsTheDaemonsText() async {
        let model = LeoSidebarModel()
        let daemon = MoveDaemon(startError: .daemon(code: "agent_moving", message: "alpha is already being moved", matches: []))
        let actions = makeActions(daemon, model: model)
        actions.move(row, to: "nas")
        await awaitCondition { await MainActor.run { model.rowErrors[row.id] != nil } }
        #expect(model.rowErrors[row.id] == "alpha is already being moved")
    }

    @Test func anOlderDaemonsNotFoundReadsAsUnsupported() async {
        let model = LeoSidebarModel()
        let unsupported = LeoDaemonError.daemon(code: "not_found", message: LeoMoveWire.unsupportedMessage, matches: [])
        let actions = makeActions(MoveDaemon(startError: unsupported), model: model)
        actions.duplicate(row, name: nil)
        await awaitCondition { await MainActor.run { model.rowErrors[row.id] != nil } }
        #expect(model.rowErrors[row.id] == "This Leo daemon can't move agents yet.")
    }

    /// A move outcome belongs to the job, not the connection: a reconnect while it runs must not drop it.
    @Test func aReconnectDuringAMoveStillPublishesTheForceOffer() async {
        let gate = Gate()
        let daemon = MoveDaemon(polls: [Self.job("failed", extra: Self.busy)], gate: gate)
        let clients = FakeMachineClients(daemon: daemon)
        let actions = makeActions(daemon, clients: clients)
        actions.move(row, to: "nas")
        await awaitCondition { await daemon.pollCount == 1 }
        clients.connect(.local, daemon)
        await gate.open()
        await awaitCondition { await MainActor.run { actions.forceOffer != nil } }
        #expect(actions.forceOffer == LeoMoveForceOffer(row: row, destination: "nas", message: "This agent is in the middle of a turn."))
    }

    @Test func aReconnectDuringAMoveStillShowsItsRefusalOnTheRow() async {
        let gate = Gate()
        let model = LeoSidebarModel()
        let daemon = MoveDaemon(polls: [Self.job("failed", extra: #","error":{"code":"no_repo","message":"not a git repo"}"#)], gate: gate)
        let clients = FakeMachineClients(daemon: daemon)
        let actions = makeActions(daemon, model: model, clients: clients)
        actions.move(row, to: "nas")
        await awaitCondition { await daemon.pollCount == 1 }
        clients.connect(.local, daemon)
        await gate.open()
        await awaitCondition { await MainActor.run { model.rowErrors[row.id] != nil } }
        #expect(model.rowErrors[row.id] == "not a git repo")
    }

    @Test func aMachineWithNoDaemonHasUnavailableDestinationsNotLoadingForever() async {
        let actions = makeActions(MoveDaemon(), clients: FakeMachineClients())
        actions.loadMoveDestinations(for: .remote("nas"))
        #expect(actions.moveDestinations(for: .remote("nas")) == .unavailable)
    }

    @Test func aSupersededWaitForDestinationsEndsWhenCancelled() async {
        let actions = makeActions(MoveDaemon())
        let wait = Task { await actions.awaitMoveDestinations(for: .local) }
        await Task.yield()
        wait.cancel()
        #expect(await wait.value == nil)
    }

    /// The menu's path: opening it must start the load itself, so a host with
    /// no daemon reads as unavailable instead of "Loading…" forever.
    @Test func openingTheMenuForAHostWithNoDaemonResolvesToUnavailable() async {
        let actions = makeActions(MoveDaemon(), clients: FakeMachineClients())
        #expect(await actions.loadedMoveDestinations(for: .remote("nas")) == .unavailable)
    }

    @Test func aWaitForDestinationsReturnsTheListOnceItLoads() async {
        let actions = makeActions(MoveDaemon())
        let wait = Task { await actions.awaitMoveDestinations(for: .local) }
        actions.loadMoveDestinations(for: .local)
        #expect(await wait.value == .unavailable)
    }

    @Test func destinationsAreUnavailableWhenTheHostListCannotBeRead() async {
        let actions = makeActions(MoveDaemon())
        #expect(actions.moveDestinations(for: .local) == nil, "nil while nothing was loaded")
        actions.loadMoveDestinations(for: .local)
        await awaitCondition { await MainActor.run { actions.moveDestinations(for: .local) == .unavailable } }
    }
}

@MainActor final class RefreshCounter { var count = 0 }

/// Holds a poll until the test opens it, so a connection can change mid-job.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor MoveDaemon: LeoDaemonClient {
    struct Sent: Equatable { let name: String; let request: LeoMoveRequest }

    private(set) var requests: [Sent] = []
    private(set) var pollCount = 0
    private var polls: [LeoMoveJob]
    private let startError: LeoDaemonError?
    private let gate: Gate?

    init(polls: [LeoMoveJob] = [], startError: LeoDaemonError? = nil, gate: Gate? = nil) {
        self.polls = polls
        self.startError = startError
        self.gate = gate
    }

    func startMove(_ name: String, _ request: LeoMoveRequest) async throws -> LeoMoveJob {
        requests.append(Sent(name: name, request: request))
        if let startError { throw startError }
        guard let first = polls.first else { throw LeoDaemonError.timeout }
        return LeoMoveJob.running(like: first)
    }

    func moveJob(id: String) async throws -> LeoMoveJob {
        pollCount += 1
        await gate?.wait()
        return polls.removeFirst()
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

private extension LeoMoveJob {
    /// The just-started form of `job`: same id and request, still running.
    static func running(like job: LeoMoveJob) -> LeoMoveJob {
        let json = #"{"id":"\#(job.id)","request":{"mode":"\#(job.request.mode.rawValue)"},"state":"running"}"#
        guard let running = try? JSONDecoder().decode(LeoMoveJob.self, from: Data(json.utf8)) else { fatalError("bad fixture") }
        return running
    }
}
