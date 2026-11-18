import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct ConfigSingletonTests {
    typealias Store = TestStore<ConfigSingleton.State, ConfigSingleton.Action>

    struct Harness {
        let store: Store
        let fake: LeoFakeConfigClient
        let revisions: LeoConfigRevisionTracker

        var core: LeoConfigSingletonState { store.state.core }

        func updates() async -> [LeoFakeConfigCall] {
            await fake.calls.filter { if case .update = $0 { true } else { false } }
        }
    }

    /// A form over the golden daemon, loaded.
    private static func harness(resource: String = "defaults") async throws -> Harness {
        let fake = try ConfigGolden.client()
        let revisions = LeoConfigRevisionTracker()
        let connection = DaemonConnection(daemon: .dionysus, secrets: DaemonSecrets(token: "t"))
        let store = TestStore(initialState: ConfigSingleton.State(resource: resource, daemon: .dionysus, connection: connection)) {
            ConfigSingleton()
        } withDependencies: {
            $0.configClients.client = { _ in fake }
            $0.configClients.revisions = { _ in revisions }
        }
        store.exhaustivity = .off
        await store.send(.task)
        await store.receive(\.loaded)
        return Harness(store: store, fake: fake, revisions: revisions)
    }

    /// Another writer changes the defaults after this form read them.
    private static func conflicted(_ harness: Harness) async {
        await harness.fake.externalChange("defaults", values: ["max_turns": .int(3)])
    }

    @Test func loadShowsForm() async throws {
        let harness = try await Self.harness()

        #expect(harness.core.phase == .loaded)
        #expect(harness.core.title == "Defaults")
        #expect(harness.core.draft?.value(at: "model") == .string("sonnet"))
        #expect(!harness.core.sections.isEmpty)
        #expect(harness.core.webLink?.host() == PairedDaemon.dionysus.baseURL.host())
    }

    @Test func clientDefaultHostPicksFromHosts() async throws {
        let harness = try await Self.harness(resource: "client")

        let control = harness.core.sections.flatMap(\.rows).first { $0.path == "default_host" }?.control
        #expect(control == .referencePicker(collection: "hosts", names: ["remote"], emptyLabel: "None"))
    }

    @Test func saveSendsChangedKeyWithRevision() async throws {
        let harness = try await Self.harness()
        let revision = await harness.fake.currentRevision
        await harness.store.send(.field("model", .string("opus")))

        await harness.store.send(.saveTapped) {
            #expect($0.core.isBusy)
        }
        await harness.store.receive(\.writeFinished)

        #expect(await harness.updates() == [.update(resource: "defaults", name: nil, patch: ["model": .string("opus")], ifMatch: revision)])
        #expect(!harness.core.isDirty)
        #expect(!harness.core.isBusy)
        #expect(harness.core.draft?.revision == (await harness.fake.currentRevision))
    }

    @Test func secondSaveIgnoredWhileBusy() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.field("model", .string("opus")))
        await harness.fake.holdWrites()

        await harness.store.send(.saveTapped)
        while await harness.fake.heldWriteCount == 0 { await Task.yield() }
        await harness.store.send(.saveTapped)
        await harness.fake.releaseWrites()
        await harness.store.receive(\.writeFinished)

        #expect(await harness.updates().count == 1)
    }

    @Test func conflictReloadKeepsEdits() async throws {
        let harness = try await Self.harness()
        await Self.conflicted(harness)
        await harness.store.send(.field("model", .string("opus")))
        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)
        #expect(harness.core.conflict != nil)
        #expect(!harness.core.canSave)

        await harness.store.send(.reloadTapped)
        await harness.store.receive(\.refreshed)

        #expect(harness.core.conflict == nil)
        #expect(harness.core.draft?.value(at: "max_turns") == .int(3))
        #expect(harness.core.draft?.patch == ["model": .string("opus")])
        #expect(harness.core.draft?.revision == (await harness.fake.currentRevision))
    }

    @Test func overwriteReplaysOverFreshRead() async throws {
        let harness = try await Self.harness()
        await Self.conflicted(harness)
        await harness.store.send(.field("model", .string("opus")))
        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)
        let current = await harness.fake.currentRevision

        await harness.store.send(.overwriteTapped)
        await harness.store.receive(\.overwriteFinished)

        let sent = await harness.updates().last
        #expect(sent == .update(resource: "defaults", name: nil, patch: ["model": .string("opus")], ifMatch: current))
        #expect(harness.core.conflict == nil)
        #expect(!harness.core.isDirty)
        let stored = try await harness.fake.document("defaults").values
        #expect(stored["max_turns"] == .int(3))
    }

    @Test func invalidLandsOnField() async throws {
        let harness = try await Self.harness()
        await harness.fake.failNextWrite(with: LeoConfigError.invalid([LeoConfigFieldError(field: "model", message: "no such model")]))
        await harness.store.send(.field("model", .string("bogus")))

        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)

        #expect(harness.core.draft?.errors(for: "model") == ["no such model"])
        #expect(harness.core.isDirty)
        #expect(!harness.core.canSave)
    }

    @Test func defaultsSaveDelegatesAgentsRestart() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.field("model", .string("opus")))
        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)
        #expect(harness.core.restartPrompt == LeoConfigRestartRequired(service: false, agents: true))

        await harness.store.send(.restartBannerTapped(.agents))

        await harness.store.receive(\.delegate.restart, .agents)
        #expect(harness.core.restartPrompt == nil)
    }

    @Test func reconnectRebasesDraft() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.machine(.connectionChanged(false)))
        await harness.store.send(.field("model", .string("opus")))
        await Self.conflicted(harness)

        await harness.store.send(.machine(.connectionChanged(true)))
        await harness.store.receive(\.refreshed)

        #expect(harness.store.state.isMachineConnected)
        #expect(harness.core.draft?.value(at: "max_turns") == .int(3))
        #expect(harness.core.draft?.patch == ["model": .string("opus")])
        #expect(harness.core.draft?.revision == (await harness.fake.currentRevision))
    }

    @Test func disconnectKeepsDraft() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.field("model", .string("opus")))

        await harness.store.send(.machine(.connectionChanged(false)))

        #expect(!harness.store.state.isMachineConnected)
        #expect(harness.core.draft?.patch == ["model": .string("opus")])
    }

    @Test func backWhileCleanLeaves() async throws {
        let harness = try await Self.harness()

        await harness.store.send(.backTapped)

        await harness.store.receive(\.delegate.leave)
        #expect(harness.store.state.leaveDialog == nil)
    }

    @Test func backWhileDirtyAsks() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.field("model", .string("opus")))

        await harness.store.send(.backTapped)

        #expect(harness.store.state.leaveDialog != nil)
        #expect(harness.core.isDirty)
    }

    @Test func leaveSaveLeavesOnceTheWriteLanded() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.field("model", .string("opus")))
        await harness.store.send(.backTapped)

        await harness.store.send(.leaveDialog(.presented(.save)))
        await harness.store.receive(\.writeFinished)

        await harness.store.receive(\.delegate.leave)
        #expect(await harness.updates().count == 1)
    }

    @Test func leaveSaveStaysOnConflict() async throws {
        let harness = try await Self.harness()
        await Self.conflicted(harness)
        await harness.store.send(.field("model", .string("opus")))
        await harness.store.send(.backTapped)

        await harness.store.send(.leaveDialog(.presented(.save)))
        await harness.store.receive(\.writeFinished)

        #expect(harness.core.conflict != nil)
        #expect(harness.core.isDirty)
        #expect(harness.store.state.leaveDialog == nil)
    }

    @Test func leaveDiscardDropsTheEdits() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.field("model", .string("opus")))
        await harness.store.send(.backTapped)

        await harness.store.send(.leaveDialog(.presented(.discard)))

        await harness.store.receive(\.delegate.leave)
        #expect(!harness.core.isDirty)
        #expect(await harness.updates().isEmpty)
    }

    @Test func newHostNamesRevalidateTheClientForm() async throws {
        let harness = try await Self.harness(resource: "client")
        await harness.store.send(.field("default_host", .string("staging")))
        #expect(!harness.core.canSave)

        await harness.store.send(.referencesChanged(["hosts": ["remote", "staging"]]))

        #expect(harness.core.canSave)
    }
}
