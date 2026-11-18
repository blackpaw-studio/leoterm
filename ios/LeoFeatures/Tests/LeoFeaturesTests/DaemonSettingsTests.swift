import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct DaemonSettingsTests {
    typealias Store = TestStore<DaemonSettings.State, DaemonSettings.Action>

    private static let connection = DaemonConnection(daemon: .dionysus, secrets: DaemonSecrets(token: "t"))

    private static func store() throws -> (Store, LeoFakeConfigClient) {
        let fake = try ConfigGolden.client()
        let revisions = LeoConfigRevisionTracker()
        let store = TestStore(initialState: DaemonSettings.State(daemon: .dionysus, connection: connection)) {
            DaemonSettings()
        } withDependencies: {
            $0.configClients.client = { _ in fake }
            $0.configClients.revisions = { _ in revisions }
            $0.continuousClock = ImmediateClock()
        }
        store.exhaustivity = .off
        return (store, fake)
    }

    @Test func sectionsServiceFirst() {
        let state = DaemonSettings.State(daemon: .dionysus, connection: Self.connection)

        #expect(state.sections == [.service, .web, .client, .hosts])
        #expect(state.sections.map(DaemonSettings.title(for:)) == ["Service", "Web UI", "Remote client", "Remote hosts"])
    }

    @Test func eachSectionOpensItsScreen() async throws {
        let (store, _) = try Self.store()

        await store.send(.sectionTapped(.service))
        #expect(store.state.destination?.service != nil)
        await store.send(.sectionTapped(.web))
        #expect(store.state.destination?.web?.core.resourceKey == "web")
        await store.send(.sectionTapped(.client))
        #expect(store.state.destination?.client?.core.resourceKey == "client")
        await store.send(.sectionTapped(.hosts))
        #expect(store.state.destination?.hosts?.core.resourceKey == "hosts")
    }

    @Test func hostAddedUpdatesClientReferences() async throws {
        let (store, _) = try Self.store()
        await store.send(.sectionTapped(.hosts))
        await store.send(.destination(.presented(.hosts(.task))))
        await store.receive(\.destination.presented.hosts.loaded)
        await store.send(.destination(.presented(.hosts(.addTapped))))
        await store.send(.destination(.presented(.hosts(.nameEntry(.presented(.textChanged("staging")))))))
        await store.send(.destination(.presented(.hosts(.nameEntry(.presented(.submitTapped))))))
        await store.receive(\.destination.presented.hosts.writeFinished)
        await store.send(.destination(.dismiss))

        await store.send(.sectionTapped(.client))
        await store.send(.destination(.presented(.client(.task))))
        await store.receive(\.destination.presented.client.loaded)

        #expect(store.state.destination?.client?.core.references["hosts"] == ["remote", "staging"])
        let control = store.state.destination?.client?.core.sections.flatMap(\.rows).first { $0.path == "default_host" }?.control
        #expect(control == .referencePicker(collection: "hosts", names: ["remote", "staging"], emptyLabel: "None"))
    }

    @Test func deletingDefaultHostConfirmSaysSo() async throws {
        let (store, _) = try Self.store()
        await store.send(.sectionTapped(.hosts))
        await store.receive(\.defaultHostRead)
        await store.send(.destination(.presented(.hosts(.task))))
        await store.receive(\.destination.presented.hosts.loaded)

        await store.send(.destination(.presented(.hosts(.deleteTapped("remote")))))

        let note = try #require(LeoDaemonPane.deleteNote(forHost: "remote", client: LeoConfigDraft(document: LeoConfigDocument(
            revision: "", values: ["default_host": .string("remote")]
        ))))
        #expect(store.state.destination?.hosts?.alert?.message == TextState("\(note) This can’t be undone."))
    }

    @Test func childRestartGoesToTheMachine() async throws {
        let (store, _) = try Self.store()
        await store.send(.sectionTapped(.web))

        await store.send(.destination(.presented(.web(.delegate(.restart(.daemon))))))

        await store.receive(\.delegate.restart, .daemon)
    }

    @Test func leavingAFormClosesIt() async throws {
        let (store, _) = try Self.store()
        await store.send(.sectionTapped(.client))

        await store.send(.destination(.presented(.client(.delegate(.leave)))))

        #expect(store.state.destination == nil)
    }

    @Test func machineNewsReachesTheOpenChild() async throws {
        let (store, _) = try Self.store()
        await store.send(.sectionTapped(.hosts))
        await store.send(.machine(.connectionChanged(false)))
        await store.receive(\.destination.presented.hosts.machine.connectionChanged, false)

        await store.send(.sectionTapped(.service))
        await store.send(.machine(.restartFinished))
        await store.receive(\.destination.presented.service.refreshRequested)
        await store.send(.machine(.scenePhaseChanged(isActive: false)))
        await store.receive(\.destination.presented.service.machine.scenePhaseChanged, false)
    }
}
