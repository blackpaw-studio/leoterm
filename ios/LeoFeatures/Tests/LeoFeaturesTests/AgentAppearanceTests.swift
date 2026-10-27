import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct AgentAppearanceTests {
    private nonisolated static let rule0 = LeoAppearanceRule(field: "environments", op: "contains", value: "homelab", color: "teal")
    private nonisolated static let fromRule = LeoAgentAppearance(emoji: nil, color: .teal, emojiSource: nil, colorSource: .rule(0))
    private nonisolated static let manual = LeoAgentAppearance(emoji: "🏛️", color: .teal, emojiSource: .manual, colorSource: .rule(0))

    private struct Refused: LocalizedError { var errorDescription: String? { "emoji must be a single emoji" } }

    private func store(
        _ appearance: LeoAgentAppearance? = nil, set: @escaping @Sendable (String, LeoAppearanceChange<String>, LeoAppearanceChange<LeoAppearanceColor>) async throws -> LeoAgentAppearance? = { _, _, _ in nil },
        rules: @escaping @Sendable () async throws -> [LeoAppearanceRule] = { [] }
    ) -> TestStoreOf<AgentAppearance> {
        TestStore(initialState: AgentAppearance.State(daemon: .dionysus, agentName: "zeus", appearance: appearance)) {
            AgentAppearance()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.appearanceRules = { _ in try await rules() }
            $0.daemonClient.setAppearance = { _, agent, emoji, color in try await set(agent, emoji, color) }
            $0.emojiRecents = LeoEmojiRecents(defaults: UserDefaults(suiteName: "leo.tests.\(UUID())")!)
        }
    }

    @Test func openingLoadsTheRulesForTheSourceLine() async {
        let store = store(Self.fromRule, rules: { [Self.rule0] })
        #expect(store.state.colorSourceText == "Teal from rule 1")
        await store.send(.task)
        await store.receive(\.rulesLoaded) { $0.rules = [Self.rule0] }
        #expect(store.state.colorSourceText == "Teal from rule 1: environments contains homelab")
    }

    @Test func aRulesFailureKeepsTheShortSourceLineAndShowsNoError() async {
        let store = store(Self.fromRule, rules: { throw Refused() })
        await store.send(.task)
        await store.receive(\.rulesLoaded)
        #expect(store.state.rules == nil)
        #expect(store.state.error == nil)
        #expect(store.state.colorSourceText == "Teal from rule 1")
    }

    @Test func pickingAnEmojiShowsAtOnceThenAdoptsTheDaemonsAnswer() async {
        let calls = LockIsolated<[String]>([])
        let store = store(Self.fromRule, set: { agent, emoji, color in
            calls.withValue { $0.append("\(agent) \(emoji) \(color)") }
            return Self.manual
        })
        await store.send(.emojiPicked("🏛️")) {
            $0.isSaving = true
            $0.appearanceBeforeWrite = Self.fromRule
            $0.appearance = LeoAgentAppearance(emoji: "🏛️", color: .teal, emojiSource: .manual, colorSource: .rule(0))
            $0.recents = ["🏛️"]
        }
        await store.receive(\.writeFinished) {
            $0.isSaving = false
            $0.appearanceBeforeWrite = nil
            $0.appearance = Self.manual
        }
        #expect(calls.value == ["zeus set(\"🏛️\") unchanged"])
    }

    @Test func noneClearsTheAgentsOwnColorAndTheRulesShowThrough() async {
        let calls = LockIsolated<[String]>([])
        let own = LeoAgentAppearance(emoji: nil, color: .purple, colorSource: .manual)
        let store = store(own, set: { _, emoji, color in
            calls.withValue { $0.append("\(emoji) \(color)") }
            return Self.fromRule
        })
        await store.send(.colorPicked(nil)) {
            $0.isSaving = true
            $0.appearanceBeforeWrite = own
            $0.appearance = nil
        }
        await store.receive(\.writeFinished) {
            $0.isSaving = false
            $0.appearanceBeforeWrite = nil
            $0.appearance = Self.fromRule
        }
        #expect(calls.value == ["unchanged cleared"])
    }

    @Test func aRefusalRevertsTheSelectionAndShowsTheReason() async {
        let store = store(Self.fromRule, set: { _, _, _ in throw Refused() })
        await store.send(.colorPicked(.red)) {
            $0.isSaving = true
            $0.appearanceBeforeWrite = Self.fromRule
            $0.appearance = LeoAgentAppearance(emoji: nil, color: .red, emojiSource: nil, colorSource: .manual)
        }
        await store.receive(\.writeFinished) {
            $0.isSaving = false
            $0.appearanceBeforeWrite = nil
            $0.appearance = Self.fromRule
            $0.error = "emoji must be a single emoji"
        }
    }

    @Test func picksAndResetAreIgnoredWhileAWriteIsInFlight() async {
        let gate = AsyncStream<Void>.makeStream()
        let calls = LockIsolated<Int>(0)
        let store = store(Self.fromRule, set: { _, _, _ in
            calls.withValue { $0 += 1 }
            for await _ in gate.stream { break }
            return Self.manual
        })
        await store.send(.colorPicked(.red)) {
            $0.isSaving = true
            $0.appearanceBeforeWrite = Self.fromRule
            $0.appearance = LeoAgentAppearance(emoji: nil, color: .red, emojiSource: nil, colorSource: .manual)
        }
        // Not one of these changes anything, and none reaches the daemon.
        await store.send(.emojiPicked("🦊"))
        await store.send(.emojiCleared)
        await store.send(.colorPicked(nil))
        await store.send(.resetTapped)
        #expect(store.state.recents.isEmpty, "an ignored pick isn't remembered")

        gate.continuation.yield()
        await store.receive(\.writeFinished) {
            $0.isSaving = false
            $0.appearanceBeforeWrite = nil
            $0.appearance = Self.manual
        }
        #expect(calls.value == 1)
    }

    @Test func aFailedWriteRevertsToTheValueFromBeforeThatWrite() async {
        let fail = LockIsolated(false)
        let store = store(Self.fromRule, set: { _, _, _ in
            if fail.value { throw Refused() }
            return Self.manual
        })
        await store.send(.emojiPicked("🏛️")) {
            $0.isSaving = true
            $0.appearanceBeforeWrite = Self.fromRule
            $0.appearance = LeoAgentAppearance(emoji: "🏛️", color: .teal, emojiSource: .manual, colorSource: .rule(0))
            $0.recents = ["🏛️"]
        }
        await store.receive(\.writeFinished) {
            $0.isSaving = false
            $0.appearanceBeforeWrite = nil
            $0.appearance = Self.manual
        }

        fail.setValue(true)
        await store.send(.colorPicked(.red)) {
            $0.isSaving = true
            $0.appearanceBeforeWrite = Self.manual
            $0.appearance = LeoAgentAppearance(emoji: "🏛️", color: .red, emojiSource: .manual, colorSource: .manual)
        }
        await store.receive(\.writeFinished) {
            $0.isSaving = false
            $0.appearanceBeforeWrite = nil
            $0.appearance = Self.manual
            $0.error = "emoji must be a single emoji"
        }
    }

    @Test func resetClearsBothAndIsOnlyOfferedForHandSetValues() async {
        let calls = LockIsolated<[String]>([])
        let store = store(Self.manual, set: { _, emoji, color in
            calls.withValue { $0.append("\(emoji) \(color)") }
            return Self.fromRule
        })
        #expect(store.state.canReset)
        await store.send(.resetTapped) {
            $0.isSaving = true
            $0.appearanceBeforeWrite = Self.manual
            $0.appearance = nil
        }
        await store.receive(\.writeFinished) {
            $0.isSaving = false
            $0.appearanceBeforeWrite = nil
            $0.appearance = Self.fromRule
        }
        #expect(calls.value == ["cleared cleared"])
        #expect(!store.state.canReset)
    }

    @Test func theFleetsLatestValueIsIgnoredWhileAWriteIsInFlight() {
        var state = AgentAppearance.State(daemon: .dionysus, agentName: "zeus", appearance: nil)
        state.receive(Self.fromRule)
        #expect(state.appearance == Self.fromRule)

        state.isSaving = true
        state.receive(nil)
        #expect(state.appearance == Self.fromRule, "the write's answer is newer")
    }
}

@MainActor
struct AgentAppearancePresentationTests {
    private nonisolated static let teal = LeoAgentAppearance(emoji: nil, color: .teal, emojiSource: nil, colorSource: .manual)

    private func initial(features: LeoDaemonFeatures) -> AppFeature.State {
        var state = AppFeature.State()
        state.fleet = Fleet.State(daemons: [.dionysus])
        state.fleet.sessions[0].agents = [Agent(.make("zeus"))]
        state.fleet.sessions[0].features = features
        return state
    }

    @Test func longPressOpensTheSheetOnlyOnADaemonThatAdvertisesAppearance() async {
        let ref = AgentRef(daemonID: PairedDaemon.dionysus.id, name: "zeus")

        let old = TestStore(initialState: initial(features: .none)) { AppFeature() }
        await old.send(.appearanceRequested(ref))
        #expect(old.state.appearance == nil)

        let current = TestStore(initialState: initial(features: LeoDaemonFeatures(["agent_appearance"]))) { AppFeature() }
        await current.send(.appearanceRequested(ref)) {
            $0.appearance = AgentAppearance.State(daemon: .dionysus, agentName: "zeus", appearance: nil)
        }
    }

    @Test func theOpenSheetFollowsTheFleet() async {
        var state = initial(features: LeoDaemonFeatures(["agent_appearance"]))
        state.appearance = AgentAppearance.State(daemon: .dionysus, agentName: "zeus", appearance: nil)
        let store = TestStore(initialState: state) { AppFeature() }

        await store.send(\.fleet.eventReceived, (PairedDaemon.dionysus.id, .agentAppearanceChanged(seq: 2, at: nil, agent: "zeus", appearance: Self.teal))) {
            $0.fleet.sessions[0].agents[id: "zeus"]?.appearance = Self.teal
            $0.appearance?.appearance = Self.teal
            $0.appearance?.fleetAppearance = Self.teal
        }
    }

    @Test func anUnrelatedFleetEventDoesNotUndoTheDaemonsAnswer() async {
        var state = initial(features: LeoDaemonFeatures(["agent_appearance"]))
        state.appearance = AgentAppearance.State(daemon: .dionysus, agentName: "zeus", appearance: nil)
        let store = TestStore(initialState: state) { AppFeature() }

        // The write's answer lands before the event stream has restated it.
        await store.send(.appearance(.presented(.writeFinished(.success(Self.teal))))) {
            $0.appearance?.appearance = Self.teal
        }
        await store.send(\.fleet.eventReceived, (PairedDaemon.dionysus.id, .agentActivity(seq: 3, at: nil, agent: "zeus", activity: .working, currentAction: nil, attention: nil))) {
            $0.fleet.sessions[0].agents[id: "zeus"]?.activity = .working
        }
        #expect(store.state.appearance?.appearance == Self.teal)
    }

    @Test func forgettingTheDaemonClosesTheSheet() async {
        var state = initial(features: LeoDaemonFeatures(["agent_appearance"]))
        state.appearance = AgentAppearance.State(daemon: .dionysus, agentName: "zeus", appearance: nil)
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.secrets.delete = { _ in }
            $0.secrets.load = { _ in nil }
            $0.pushClient.sharePairedDaemons = { _ in }
            $0.pairedDaemons.save = { _ in }
        }
        await store.send(\.daemons.forgetButtonTapped, .dionysus) { $0.daemons.alert = Daemons.forgetAlert(.dionysus) }
        await store.send(\.daemons.alert.presented.confirmForget, PairedDaemon.dionysus.id) { $0.daemons.alert = nil }
        await store.receive(\.daemons.delegate.forget) {
            $0.fleet.sessions.remove(id: PairedDaemon.dionysus.id)
            $0.appearance = nil
        }
    }
}
