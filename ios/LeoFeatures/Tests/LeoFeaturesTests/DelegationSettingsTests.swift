import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct DelegationSettingsTests {
    typealias Store = TestStore<DelegationSettings.State, DelegationSettings.Action>

    struct Harness {
        let store: Store
        let fake: LeoFakeConfigClient

        var core: LeoDelegationPaneState { store.state.core }

        func writes() async -> [(write: LeoFakeDelegationWrite, ifMatch: String)] {
            await fake.calls.compactMap { call in
                if case .delegationWrite(let write, let ifMatch) = call { (write, ifMatch) } else { nil }
            }
        }
    }

    /// The pane over a fake daemon serving `document` (nil: no delegation block), loaded.
    private static func harness(_ document: LeoDelegationDocument? = DelegationGolden.document()) async throws -> Harness {
        let fake = try ConfigGolden.client(delegation: document)
        let revisions = LeoConfigRevisionTracker()
        let connection = DaemonConnection(daemon: .dionysus, secrets: DaemonSecrets(token: "t"))
        let store = TestStore(initialState: DelegationSettings.State(daemon: .dionysus, connection: connection)) {
            DelegationSettings()
        } withDependencies: {
            $0.configClients.client = { _ in fake }
            $0.configClients.revisions = { _ in revisions }
        }
        store.exhaustivity = .off
        await store.send(.task)
        await store.receive(\.loaded)
        return Harness(store: store, fake: fake)
    }

    private static func untilHeld(_ fake: LeoFakeConfigClient) async {
        await settle { await fake.heldWriteCount > 0 }
    }

    @Test func notConfiguredShowsEmptyState() async throws {
        let harness = try await Self.harness(nil)

        #expect(harness.core.phase == .loaded)
        #expect(!harness.core.isConfigured)
        await harness.store.send(.cellTapped(profile: "fast", role: "coder"))
        await harness.store.send(.enabledToggled(false))
        #expect(harness.core.cellEditor == nil)
        #expect(await harness.writes().isEmpty)
    }

    @Test func profilesDrillDownToTheirRoles() async throws {
        let harness = try await Self.harness()

        await harness.store.send(.profileTapped("deep"))

        #expect(harness.store.state.openProfile == "deep")
        let rows = harness.store.state.roles(in: "deep")
        #expect(rows.map(\.role) == ["coder", "qa"])
        #expect(rows.map(\.summary) == ["coder · opus", "reviewer · sonnet · high"])
        #expect(harness.store.state.roles(in: "fast").map(\.summary) == ["reviewer · haiku", "Not routed"])
    }

    @Test func cellSaveSendsMergedCellWithRevision() async throws {
        let harness = try await Self.harness()
        let revision = await harness.fake.currentRevision
        await harness.store.send(.cellTapped(profile: "deep", role: "qa"))
        await harness.store.send(.cellEffortChanged("low"))

        await harness.store.send(.cellSaveTapped)
        await harness.store.receive(\.writeFinished)

        let sent = try #require(await harness.writes().last)
        #expect(sent.ifMatch == revision)
        #expect(sent.write == .cell(profile: "deep", role: "qa", target: LeoDelegationTarget(template: "reviewer", model: "sonnet", effort: "low")))
        #expect(harness.core.cellEditor == nil)
        #expect(harness.core.matrix.cell(profile: "deep", role: "qa")?.effort == "low")
    }

    @Test func cellConflictKeepsEditOffersReloadOverwrite() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.cellTapped(profile: "deep", role: "qa"))
        await harness.store.send(.cellEffortChanged("low"))
        await harness.fake.externalDelegationChange(
            profile: "deep", role: "qa", target: LeoDelegationTarget(template: "reviewer", model: "opus", effort: "high")
        )

        await harness.store.send(.cellSaveTapped)
        await harness.store.receive(\.writeFinished)
        #expect(harness.core.conflict?.operation == .cell)
        #expect(harness.core.cellEditor?.edit.target.effort == "low")

        await harness.store.send(.reloadTapped)
        await harness.store.receive(\.reread)
        #expect(harness.core.conflict == nil)
        #expect(harness.core.cellEditor?.edit.target == LeoDelegationTarget(template: "reviewer", model: "opus", effort: "low"))

        await harness.fake.externalChange("web", values: [:])
        await harness.store.send(.cellSaveTapped)
        await harness.store.receive(\.writeFinished)
        #expect(harness.core.conflict != nil)
        let current = await harness.fake.currentRevision
        await harness.store.send(.overwriteTapped)
        await harness.store.receive(\.writeFinished)
        #expect(harness.core.conflict == nil)
        #expect(await harness.writes().last?.ifMatch == current)
        #expect(harness.core.matrix.cell(profile: "deep", role: "qa")?.target == LeoDelegationTarget(template: "reviewer", model: "opus", effort: "low"))
    }

    @Test func enabledShowsPendingAndRollsBackOnFailure() async throws {
        let harness = try await Self.harness()
        await harness.fake.failNextWrite(with: LeoDaemonError.transport("tunnel down"))

        await harness.store.send(.enabledToggled(false)) {
            #expect($0.core.displayedEnabled == false)
            #expect($0.core.isBusy)
        }
        await harness.store.receive(\.writeFinished)

        #expect(harness.core.displayedEnabled == true)
        #expect(harness.core.errorMessage != nil)
    }

    @Test func activatePreviewsThenWritesOnConfirm() async throws {
        let harness = try await Self.harness()

        await harness.store.send(.activateTapped("deep")) {
            #expect($0.core.preview == .loading("deep"))
        }
        await harness.store.receive(\.previewLoaded)
        guard case .loaded(let preview)? = harness.core.preview else {
            Issue.record("Expected the preview")
            return
        }
        #expect(preview.profile == "deep")
        #expect(await harness.writes().isEmpty)

        await harness.store.send(.activateConfirmTapped)
        await harness.store.receive(\.writeFinished)

        #expect(await harness.writes().map(\.write) == [.active("deep")])
        #expect(harness.core.document?.activeProfile == "deep")
        #expect(harness.core.preview == nil)
    }

    @Test func lateProfilePreviewDropped() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.activateTapped("deep"))
        await harness.store.send(.activateCancelTapped)

        await harness.store.send(.previewLoaded(.loaded(LeoDelegationPreview(profile: "deep")), profile: "deep"))

        #expect(harness.core.preview == nil)
    }

    @Test func deleteRoleConfirmActsOnAlertPayload() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.deleteRoleTapped("qa"))
        #expect(harness.store.state.alert != nil)
        #expect(harness.core.confirmation == .deleteRole(name: "qa", profiles: ["deep"]))

        await harness.store.send(.alert(.presented(.confirm(.deleteRole(name: "qa", profiles: ["deep"])))))
        await harness.store.receive(\.writeFinished)

        #expect(await harness.writes().map(\.write) == [.deleteRole("qa")])
        #expect(harness.core.matrix.rows.map(\.role.name) == ["coder"])
    }

    @Test func addRoleNameErrorInline() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.addRoleTapped)
        #expect(harness.store.state.nameEntry?.choices == ["coder", "reviewer"])

        await harness.store.send(.nameEntry(.presented(.textChanged("coder"))))
        #expect(harness.store.state.nameEntry?.error != nil)
        await harness.store.send(.nameEntry(.presented(.submitTapped)))
        #expect(await harness.writes().isEmpty)

        await harness.store.send(.nameEntry(.presented(.textChanged("scout"))))
        await harness.store.send(.nameEntry(.presented(.choiceChanged("reviewer"))))
        await harness.store.send(.nameEntry(.presented(.submitTapped)))
        await harness.store.receive(\.writeFinished)

        #expect(await harness.writes().map(\.write) == [.addRole(name: "scout", template: "reviewer")])
        #expect(harness.store.state.nameEntry == nil)
    }

    @Test func hiddenAgentsSaveWholeList() async throws {
        let harness = try await Self.harness(DelegationGolden.document(hideNativeAgents: ["Explore"]))
        await harness.store.send(.hiddenAgentsTapped)
        #expect(harness.store.state.isEditingHiddenAgents)

        await harness.store.send(.hiddenAgentsChanged(["Explore", " Plan "]))
        await harness.store.send(.hiddenAgentsSaveTapped)
        await harness.store.receive(\.writeFinished)

        #expect(await harness.writes().map(\.write) == [.hideAgents(["Explore", "Plan"])])
        #expect(!harness.store.state.isEditingHiddenAgents)
        #expect(harness.core.hiddenAgentNames == ["Explore", "Plan"])
    }

    @Test func restructureDisabledWhileDirty() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.useForTapped("coder"))
        await harness.store.send(.useForTextChanged("shipping code"))

        #expect(!harness.core.canRestructure)
        await harness.store.send(.addProfileTapped)
        await harness.store.send(.deleteProfileTapped("deep"))
        #expect(harness.store.state.nameEntry == nil)
        #expect(harness.store.state.alert == nil)
    }

    @Test func secondWriteIgnoredWhileBusy() async throws {
        let harness = try await Self.harness()
        await harness.fake.holdWrites()

        await harness.store.send(.enabledToggled(false))
        await Self.untilHeld(harness.fake)
        await harness.store.send(.enabledToggled(true))
        await harness.fake.releaseWrites()
        await harness.store.receive(\.writeFinished)

        #expect(await harness.writes().map(\.write) == [.enabled(false)])
    }

    @Test func aRestartBannerAsksTheMachine() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.enabledToggled(false))
        await harness.store.receive(\.writeFinished)
        #expect(harness.core.restartPrompt == LeoConfigRestartRequired(service: true, agents: true))

        await harness.store.send(.restartBannerTapped(.daemon))

        await harness.store.receive(\.delegate.restart, .daemon)
        #expect(harness.core.restartPrompt == nil)
    }

    @Test func aDaemonWithoutTheRouteFailsWithRetry() async throws {
        let fake = try ConfigGolden.client(delegation: DelegationGolden.document())
        await fake.failNextRead(with: LeoDaemonError.daemon(code: "not_found", message: "no such route", matches: []))
        let connection = DaemonConnection(daemon: .dionysus, secrets: DaemonSecrets(token: "t"))
        let store = TestStore(initialState: DelegationSettings.State(daemon: .dionysus, connection: connection)) {
            DelegationSettings()
        } withDependencies: {
            $0.configClients.client = { _ in fake }
            $0.configClients.revisions = { _ in LeoConfigRevisionTracker() }
        }
        store.exhaustivity = .off

        await store.send(.task)
        await store.receive(\.loaded)
        guard case .failed = store.state.core.phase else {
            Issue.record("Expected the failed phase")
            return
        }
        await store.send(.task)
        await store.receive(\.loaded)
        #expect(store.state.core.phase == .loaded)
    }

    @Test func reconnectRebasesEdits() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.cellTapped(profile: "deep", role: "qa"))
        await harness.store.send(.cellEffortChanged("low"))
        await harness.store.send(.machine(.connectionChanged(false)))
        await harness.fake.externalDelegationChange(
            profile: "deep", role: "qa", target: LeoDelegationTarget(template: "reviewer", model: "opus", effort: "high")
        )

        await harness.store.send(.machine(.connectionChanged(true)))
        await harness.store.receive(\.reread)

        #expect(harness.core.cellEditor?.edit.target == LeoDelegationTarget(template: "reviewer", model: "opus", effort: "low"))
        #expect(harness.core.cellEditor?.baseRevision == (await harness.fake.currentRevision))
    }
}
