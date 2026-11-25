import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

struct AgentBriefRowsTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func presentation(_ brief: LeoAgentBrief, lastActivity: Date? = nil) -> LeoAgentBriefPresentation {
        LeoAgentBriefPresentation(brief: brief, lastActivity: lastActivity, now: now)!
    }

    @Test func rowsFollowTheSpecOrderAndSkipWhatIsAbsent() {
        let brief = LeoAgentBrief(
            goal: "Ship the brief", status: "Waiting on CI", decisions: ["Use TCA", " "], open: ["Review"],
            updatedAt: now.addingTimeInterval(-720)
        )

        let rows = AgentBriefRows.make(presentation(brief))

        #expect(rows.map(\.kind) == [.goal, .status, .decision, .open, .updated])
        #expect(rows.map(\.text) == ["Ship the brief", "Waiting on CI", "Use TCA", "Review", "Updated 12m ago"])
        #expect(rows.allSatisfy { !$0.isMuted })
    }

    @Test func aStaleBriefMutesItsAge() {
        let brief = LeoAgentBrief(goal: "Old", updatedAt: now.addingTimeInterval(-3 * 86_400))

        let rows = AgentBriefRows.make(presentation(brief, lastActivity: now))

        #expect(rows.last?.kind == .updated)
        #expect(rows.last?.isMuted == true)
    }

    @Test func noPresentationMeansNoRows() {
        #expect(AgentBriefRows.make(nil).isEmpty)
    }
}

@MainActor
struct ChatThreadBriefTests {
    @Test func theBriefHeaderStartsCollapsedAndToggles() async {
        let store = TestStore(initialState: ChatThread.State(daemon: .dionysus, agent: "zeus")) { ChatThread() }

        await store.send(.briefToggled) { $0.isBriefExpanded = true }
        await store.send(.briefToggled) { $0.isBriefExpanded = false }
    }

    @Test func anotherAgentsThreadStartsCollapsedAgain() {
        var first = ChatThread.State(daemon: .dionysus, agent: "zeus")
        first.isBriefExpanded = true

        #expect(ChatThread.State(daemon: .dionysus, agent: "hera").isBriefExpanded == false)
    }
}

@MainActor
struct DaemonBriefSettingsTests {
    typealias Store = TestStore<DaemonSettings.State, DaemonSettings.Action>
    private static let connection = DaemonConnection(daemon: .dionysus, secrets: DaemonSecrets(token: "t"))

    private static func make(supported: Bool = true, enabled: Bool? = nil) -> (Store, LeoFakeConfigClient) {
        let values: [String: LeoConfigValue] = enabled.map { [LeoAgentBriefWire.enabledField: .bool($0)] } ?? [:]
        let fake = LeoFakeConfigClient(
            schema: LeoConfigSchema(resources: []),
            singletons: [LeoAgentBriefWire.configResource: LeoConfigItem(name: "", values: values)]
        )
        let revisions = LeoConfigRevisionTracker()
        let store = TestStore(
            initialState: DaemonSettings.State(daemon: .dionysus, connection: connection, supportsBrief: supported)
        ) {
            DaemonSettings()
        } withDependencies: {
            $0.configClients.client = { _ in fake }
            $0.configClients.revisions = { _ in revisions }
        }
        store.exhaustivity = .off
        return (store, fake)
    }

    @Test func loadsTheSwitchFromTheBriefResource() async {
        let (store, fake) = Self.make(enabled: true)

        await store.send(.task)
        await store.receive(\.briefLoaded)

        #expect(store.state.isBriefEnabled == true)
        #expect(store.state.briefRevision == (await fake.currentRevision))
    }

    @Test func aDaemonWithoutTheFeatureIsNeverAsked() async {
        let (store, fake) = Self.make(supported: false)

        await store.send(.task)

        #expect((await fake.calls).isEmpty)
        #expect(store.state.isBriefEnabled == nil)
    }

    @Test func togglingWritesEnabledWithTheLoadedRevision() async {
        let (store, fake) = Self.make(enabled: false)
        await store.send(.task)
        await store.receive(\.briefLoaded)
        let loaded = await fake.currentRevision

        await store.send(.briefToggled(true))
        await store.receive(\.briefSaved)
        await store.receive(\.briefLoaded)

        let calls = await fake.calls
        #expect(calls.contains(.update(
            resource: "brief", name: nil, patch: [LeoAgentBriefWire.enabledField: .bool(true)], ifMatch: loaded
        )))
        #expect(store.state.isBriefEnabled == true)
        #expect(store.state.briefRevision == (await fake.currentRevision))
        #expect(store.state.isBriefSaving == false)
    }

    @Test func theSwitchFollowsTheTapAtOnceAndRevertsWhenTheWriteFails() async {
        let (store, fake) = Self.make(enabled: false)
        await store.send(.task)
        await store.receive(\.briefLoaded)
        await fake.failNextWrite(with: LeoDaemonError.timeout)

        await store.send(.briefToggled(true))
        #expect(store.state.isBriefEnabled == true)

        await store.receive(\.briefSaved)
        #expect(store.state.isBriefEnabled == false)
        #expect(store.state.alert != nil)
    }

    @Test func aConflictAlertsAndShowsTheMachinesValue() async {
        let (store, fake) = Self.make(enabled: false)
        await store.send(.task)
        await store.receive(\.briefLoaded)
        await fake.externalChange("brief", values: [LeoAgentBriefWire.enabledField: .bool(true)])

        await store.send(.briefToggled(true))
        await store.receive(\.briefSaved)

        #expect(store.state.alert != nil)
        #expect(store.state.isBriefSaving == false)
        await store.receive(\.briefLoaded)
        #expect(store.state.isBriefEnabled == true)
        #expect(store.state.briefRevision == (await fake.currentRevision))
    }
}
