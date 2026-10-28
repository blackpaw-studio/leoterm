import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct AgentMoveTests {
    typealias Move = AgentMove

    private static func store(
        _ intent: Move.Intent, move: @escaping @Sendable (String, LeoMoveRequest) async throws -> LeoAgentMoveOutcome
    ) -> TestStoreOf<Move> {
        TestStore(initialState: Move.State(daemon: .dionysus, agentName: "zeus", intent: intent)) {
            Move()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.move = { _, agent, request in try await move(agent, request) }
        }
    }

    private nonisolated static let done = LeoAgentMoveOutcome.done(LeoMoveResult(name: "zeus", to: "nas"))

    @Test func aMoveIsConfirmedFirstThenSendsTheExactRequest() async {
        let sent = LockIsolated<[String]>([])
        let store = Self.store(.move(to: "nas")) { agent, request in
            sent.withValue { $0.append("\(agent) \(request.mode.rawValue) \(request.to ?? "-") force=\(request.force)") }
            return Self.done
        }
        #expect(store.state.confirmation == Move.confirmation(for: .move(to: "nas"), agent: "zeus"))
        #expect(sent.value.isEmpty)
        await store.send(\.confirmation.presented.start, false) {
            $0.confirmation = nil
            $0.isMoving = true
        }
        await store.receive(\.finished) { $0.isMoving = false }
        await store.receive(\.delegate.completed)
        #expect(sent.value == ["zeus move nas force=false"])
    }

    @Test func cancellingTheMoveConfirmationSendsNothing() async {
        let store = Self.store(.move(to: "nas")) { _, _ in Issue.record("no request"); return Self.done }
        await store.send(\.confirmation.dismiss) { $0.confirmation = nil }
        await store.receive(\.delegate.dismissed)
    }

    @Test func aCopyAsksForAnOptionalNameThenSendsIt() async {
        let sent = LockIsolated<[LeoMoveRequest]>([])
        let store = Self.store(.copy(to: "nas")) { _, request in sent.withValue { $0.append(request) }; return Self.done }
        #expect(store.state.isAskingName)
        await store.send(.nameSubmitted("twin")) {
            $0.isAskingName = false
            $0.isMoving = true
        }
        await store.receive(\.finished) { $0.isMoving = false }
        await store.receive(\.delegate.completed)
        #expect(sent.value == [.copy(to: "nas", name: "twin")])
    }

    @Test func aBlankNameLetsTheDaemonPickOne() async {
        let sent = LockIsolated<[LeoMoveRequest]>([])
        let store = Self.store(.duplicate) { _, request in sent.withValue { $0.append(request) }; return Self.done }
        await store.send(.nameSubmitted("   ")) {
            $0.isAskingName = false
            $0.isMoving = true
        }
        await store.receive(\.finished) { $0.isMoving = false }
        await store.receive(\.delegate.completed)
        #expect(sent.value == [.duplicate(name: nil)])
    }

    @Test func cancellingTheNamePromptSendsNothing() async {
        let store = Self.store(.duplicate) { _, _ in Issue.record("no request"); return Self.done }
        await store.send(.nameCancelled) { $0.isAskingName = false }
        await store.receive(\.delegate.dismissed)
    }

    @Test func aRefusalShowsTheDaemonsText() async {
        let store = Self.store(.move(to: "nas")) { _, _ in
            .refused(code: "host_unreachable", message: "nas is unreachable", offersForce: false)
        }
        await store.send(\.confirmation.presented.start, false) {
            $0.confirmation = nil
            $0.isMoving = true
        }
        await store.receive(\.finished) {
            $0.isMoving = false
            $0.alert = Move.failureAlert("Couldn't move zeus", "nas is unreachable")
        }
        await store.send(\.alert.dismiss) { $0.alert = nil }
        await store.receive(\.delegate.dismissed)
    }

    @Test func aBusyAgentsMoveOffersForceAndSendsIt() async {
        let sent = LockIsolated<[LeoMoveRequest]>([])
        let store = Self.store(.move(to: "nas")) { _, request in
            sent.withValue { $0.append(request) }
            return request.force ? Self.done : .refused(code: "agent_busy", message: "This agent is in the middle of a turn.", offersForce: true)
        }
        await store.send(\.confirmation.presented.start, false) {
            $0.confirmation = nil
            $0.isMoving = true
        }
        await store.receive(\.finished) {
            $0.isMoving = false
            $0.confirmation = Move.busyConfirmation(agent: "zeus", message: "This agent is in the middle of a turn.")
        }
        await store.send(\.confirmation.presented.start, true) {
            $0.confirmation = nil
            $0.isMoving = true
        }
        await store.receive(\.finished) { $0.isMoving = false }
        await store.receive(\.delegate.completed)
        #expect(sent.value == [.move(to: "nas"), .move(to: "nas", force: true)])
    }

    @Test func aRequestThatThrowsShowsItsReason() async {
        struct Down: LocalizedError { var errorDescription: String? { "nas is down" } }
        let store = Self.store(.move(to: "nas")) { _, _ in throw Down() }
        await store.send(\.confirmation.presented.start, false) {
            $0.confirmation = nil
            $0.isMoving = true
        }
        await store.receive(\.finished) {
            $0.isMoving = false
            $0.alert = Move.failureAlert("Couldn't move zeus", "nas is down")
        }
    }

    @Test func anOutcomeThatCannotBeConfirmedSaysSoAndRefreshes() async {
        let store = Self.store(.move(to: "nas")) { _, _ in .unknown("The move can no longer be found.") }
        await store.send(\.confirmation.presented.start, false) {
            $0.confirmation = nil
            $0.isMoving = true
        }
        await store.receive(\.finished) {
            $0.isMoving = false
            $0.alert = Move.failureAlert("Couldn't confirm the move of zeus", "The move can no longer be found.")
        }
        await store.receive(\.delegate.completed)
    }

    @Test func aCopyDoneRefreshesTheFleetToo() async {
        let store = Self.store(.duplicate) { _, _ in Self.done }
        await store.send(.nameSubmitted("")) {
            $0.isAskingName = false
            $0.isMoving = true
        }
        await store.receive(\.finished) { $0.isMoving = false }
        await store.receive(\.delegate.completed)
    }
}
