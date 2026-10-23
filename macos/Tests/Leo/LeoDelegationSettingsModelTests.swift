import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor struct LeoDelegationSettingsModelTests {
    private struct Harness {
        let model: LeoDelegationSettingsModel
        let fake: LeoFakeConfigClient
        let revisions: LeoConfigRevisionTracker
    }

    private static func harness(_ document: LeoDelegationDocument? = LeoDelegationFixtures.document()) async throws -> Harness {
        let fake = try LeoConfigGolden.client(delegation: document)
        let revisions = LeoConfigRevisionTracker()
        let model = LeoDelegationSettingsModel(client: fake, revisions: revisions, machineHost: "dionysus")
        await model.load()
        return Harness(model: model, fake: fake, revisions: revisions)
    }

    private static func writes(_ fake: LeoFakeConfigClient) async -> [(write: LeoFakeDelegationWrite, ifMatch: String)] {
        await fake.calls.compactMap { call in
            if case .delegationWrite(let write, let ifMatch) = call { (write, ifMatch) } else { nil }
        }
    }

    private static func writeCount(_ fake: LeoFakeConfigClient) async -> Int {
        await writes(fake).count
    }

    /// Lets a held request reach the fake without a wall-clock wait.
    private static func untilHeld(_ fake: LeoFakeConfigClient) async {
        while await fake.heldWriteCount == 0 { await Task.yield() }
    }

    // MARK: loading

    @Test func loadingReadsTheDocumentIntoAMatrix() async throws {
        let harness = try await Self.harness()

        #expect(harness.model.phase == .loaded)
        #expect(harness.model.isConfigured)
        #expect(harness.model.matrix.rows.map(\.role.name) == ["coder", "qa"])
        #expect(harness.model.matrix.profiles.map(\.name) == ["deep", "fast"])
        #expect(!harness.model.hasUnsavedChanges)
    }

    @Test func aMachineWithNoDelegationBlockIsNotConfiguredAndEditsNothing() async throws {
        let harness = try await Self.harness(nil)
        harness.model.beginCellEdit(profile: "fast", role: "coder")
        await harness.model.setEnabled(true)

        #expect(harness.model.phase == .loaded)
        #expect(!harness.model.isConfigured)
        #expect(harness.model.cellEditor == nil)
        #expect(await Self.writeCount(harness.fake) == 0)
    }

    @Test func aFailedLoadSaysWhy() async throws {
        let fake = try LeoConfigGolden.client(delegation: LeoDelegationFixtures.document())
        await fake.failNextRead(with: LeoDaemonError.transport("tunnel down"))
        let model = LeoDelegationSettingsModel(client: fake, revisions: LeoConfigRevisionTracker(), machineHost: "dionysus")

        await model.load()

        guard case .failed = model.phase else {
            Issue.record("Expected a failed load, got \(model.phase)")
            return
        }
    }

    @Test func warningsAndRecentConsultsAreReadFromTheDocument() async throws {
        let consult = LeoDelegationConsult(id: "d-1", role: "coder", profile: "fast", template: "reviewer", status: "done")
        let harness = try await Self.harness(LeoDelegationFixtures.document(warnings: ["role \"x\" has no template"], consults: [consult]))

        #expect(harness.model.warnings == ["role \"x\" has no template"])
        #expect(harness.model.recentConsults == [consult])
    }

    // MARK: cell edits

    @Test func aCellSaveSendsTheMergedCellWithTheRevisionAndClosesTheEditor() async throws {
        let harness = try await Self.harness()
        let revision = await harness.fake.currentRevision

        harness.model.beginCellEdit(profile: "fast", role: "qa")
        harness.model.setCellTemplate("coder")
        harness.model.setCellEffort("high")
        #expect(harness.model.hasUnsavedChanges)
        await harness.model.saveCellEdit()

        let writes = await Self.writes(harness.fake)
        #expect(writes.count == 1)
        #expect(writes.first?.write == .cell(profile: "fast", role: "qa", target: LeoDelegationTarget(template: "coder", effort: "high")))
        #expect(writes.first?.ifMatch == revision)
        #expect(harness.model.cellEditor == nil)
        #expect(!harness.model.hasUnsavedChanges)
        #expect(harness.model.matrix.cell(profile: "fast", role: "qa")?.effort == "high")
        #expect(harness.model.restartPrompt?.agents == true)
    }

    @Test func clearingTheTemplateDeletesTheCell() async throws {
        let harness = try await Self.harness()

        harness.model.beginCellEdit(profile: "deep", role: "qa")
        harness.model.setCellTemplate("")
        await harness.model.saveCellEdit()

        #expect(await Self.writes(harness.fake).first?.write == .cell(profile: "deep", role: "qa", target: LeoDelegationTarget(template: "", model: "sonnet", effort: "high")))
        #expect(harness.model.matrix.cell(profile: "deep", role: "qa") == nil)
    }

    @Test func aCleanEditorSendsNothing() async throws {
        let harness = try await Self.harness()

        harness.model.beginCellEdit(profile: "deep", role: "coder")
        await harness.model.saveCellEdit()

        #expect(await Self.writeCount(harness.fake) == 0)
    }

    @Test func aRejectedEffortLandsOnTheEffortFieldAndKeepsTheEditorOpen() async throws {
        let harness = try await Self.harness()
        let revision = await harness.fake.currentRevision

        harness.model.beginCellEdit(profile: "deep", role: "coder")
        harness.model.setCellEffort("ludicrous")
        await harness.model.saveCellEdit()

        #expect(harness.model.cellEditor?.errors["effort"] != nil)
        #expect(harness.model.cellEditor?.edit.target.effort == "ludicrous")
        #expect(await harness.fake.currentRevision == revision)
        harness.model.setCellEffort("low")
        #expect(harness.model.cellEditor?.errors["effort"] == nil)
    }

    @Test func cancellingTheEditorDropsItWithoutAWrite() async throws {
        let harness = try await Self.harness()

        harness.model.beginCellEdit(profile: "deep", role: "coder")
        harness.model.setCellModel("sonnet")
        harness.model.cancelCellEdit(profile: "deep", role: "coder")

        #expect(harness.model.cellEditor == nil)
        #expect(!harness.model.hasUnsavedChanges)
        #expect(await Self.writeCount(harness.fake) == 0)
    }

    @Test func aLateCloseOfAnotherCellsPopoverDoesNotDropTheCurrentEditor() async throws {
        let harness = try await Self.harness()

        harness.model.beginCellEdit(profile: "deep", role: "qa")
        harness.model.cancelCellEdit(profile: "deep", role: "coder")

        #expect(harness.model.cellEditor?.profile == "deep")
        #expect(harness.model.cellEditor?.role == "qa")
    }

    // MARK: conflicts on a cell

    @Test func aCellEditedWhileAnotherWriterChangedItsTemplateConflictsAndKeepsTheEdit() async throws {
        let harness = try await Self.harness()
        harness.model.beginCellEdit(profile: "deep", role: "coder")
        harness.model.setCellEffort("high")
        await harness.fake.externalDelegationChange(profile: "deep", role: "coder", target: LeoDelegationTarget(template: "reviewer"))

        await harness.model.saveCellEdit()

        #expect(harness.model.conflict != nil)
        #expect(harness.model.cellEditor?.edit.target.effort == "high")
        #expect(harness.model.matrix.cell(profile: "deep", role: "coder")?.template == "coder")
    }

    @Test func reloadingAfterAConflictKeepsTheEditedKeysOverTheNewCell() async throws {
        let harness = try await Self.harness()
        harness.model.beginCellEdit(profile: "deep", role: "coder")
        harness.model.setCellEffort("high")
        await harness.fake.externalDelegationChange(profile: "deep", role: "coder", target: LeoDelegationTarget(template: "reviewer"))
        await harness.model.saveCellEdit()

        await harness.model.reloadAfterConflict()

        #expect(harness.model.conflict == nil)
        #expect(harness.model.cellEditor?.edit.target == LeoDelegationTarget(template: "reviewer", effort: "high"))
        #expect(harness.model.cellEditor?.edit.changedKeys == [.effort])
        await harness.model.saveCellEdit()
        #expect(await Self.writes(harness.fake).last?.write == .cell(profile: "deep", role: "coder", target: LeoDelegationTarget(template: "reviewer", effort: "high")))
        #expect(harness.model.cellEditor == nil)
    }

    @Test func overwritingAfterAConflictResendsOnlyTheUsersEditsOverTheCurrentCell() async throws {
        let harness = try await Self.harness()
        harness.model.beginCellEdit(profile: "deep", role: "coder")
        harness.model.setCellEffort("high")
        await harness.fake.externalDelegationChange(profile: "deep", role: "coder", target: LeoDelegationTarget(template: "reviewer", model: "haiku"))
        await harness.model.saveCellEdit()

        await harness.model.overwrite()

        #expect(await Self.writes(harness.fake).last?.write == .cell(
            profile: "deep", role: "coder", target: LeoDelegationTarget(template: "reviewer", model: "haiku", effort: "high")
        ))
        #expect(harness.model.conflict == nil)
        #expect(harness.model.cellEditor == nil)
    }

    // MARK: single-key writes beside an open edit

    @Test func aToggleBesideAnOpenEditRebasesTheEditAndItsSaveStillGoesThrough() async throws {
        let harness = try await Self.harness()
        harness.model.beginCellEdit(profile: "deep", role: "coder")
        harness.model.setCellEffort("high")

        await harness.model.setEnabled(false)

        #expect(harness.model.cellEditor?.edit.target.effort == "high")
        #expect(harness.model.cellEditor?.baseRevision == harness.model.document?.revision)
        await harness.model.saveCellEdit()
        #expect(harness.model.conflict == nil)
        #expect(harness.model.cellEditor == nil)
        let writes = await Self.writes(harness.fake)
        #expect(writes.map(\.write) == [.enabled(false), .cell(profile: "deep", role: "coder", target: LeoDelegationTarget(template: "coder", effort: "high"))])
    }

    @Test func aToggleRetriedAgainstAnotherWritersRevisionNeverRebasesAnEditUntilItsSaveConflicts() async throws {
        let harness = try await Self.harness()
        harness.model.beginCellEdit(profile: "deep", role: "coder")
        harness.model.setCellEffort("high")
        await harness.fake.externalChange("web", values: [:])

        await harness.model.setEnabled(false)
        await harness.model.setEnabled(true)

        #expect(await Self.writes(harness.fake).map(\.write) == [.enabled(false), .enabled(false), .enabled(true)])
        #expect(harness.model.cellEditor?.baseRevision != harness.model.document?.revision)
        await harness.model.saveCellEdit()
        #expect(harness.model.conflict != nil)
        #expect(harness.model.cellEditor?.edit.target.effort == "high")
    }

    @Test func theEnabledSwitchShowsTheNewValueWhileTheWriteIsInFlight() async throws {
        let harness = try await Self.harness()
        await harness.fake.holdWrites()

        let toggle = Task { await harness.model.setEnabled(false) }
        await Self.untilHeld(harness.fake)

        #expect(harness.model.displayedEnabled == false)
        #expect(harness.model.document?.enabled == true)
        await harness.fake.releaseWrites()
        await toggle.value
        #expect(harness.model.document?.enabled == false)
        #expect(harness.model.displayedEnabled == false)
    }

    @Test func aFailedToggleShowsTheRealValueAgainAndSaysWhy() async throws {
        let harness = try await Self.harness()
        await harness.fake.failNextWrite(with: LeoDaemonError.transport("tunnel down"))

        await harness.model.setEnabled(false)

        #expect(harness.model.displayedEnabled == true)
        #expect(harness.model.errorMessage != nil)
    }

    // MARK: reconnect

    @Test func aReconnectKeepsADirtyEditOverTheFreshDocument() async throws {
        let harness = try await Self.harness()
        harness.model.beginCellEdit(profile: "deep", role: "coder")
        harness.model.setCellEffort("high")
        await harness.fake.externalDelegationChange(profile: "fast", role: "coder", target: LeoDelegationTarget(template: "coder"))

        await harness.model.reload(using: harness.fake)

        #expect(harness.model.matrix.cell(profile: "fast", role: "coder")?.template == "coder")
        #expect(harness.model.cellEditor?.edit.target.effort == "high")
        #expect(harness.model.cellEditor?.baseRevision == harness.model.document?.revision)
        await harness.model.saveCellEdit()
        #expect(harness.model.conflict == nil)
    }

    @Test func discardingDropsEveryOpenEdit() async throws {
        let harness = try await Self.harness()
        harness.model.beginCellEdit(profile: "deep", role: "coder")
        harness.model.setCellEffort("high")
        harness.model.beginUseForEdit(role: "qa")
        harness.model.setUseForText("changed")
        harness.model.setHiddenAgents(["Explore"])
        #expect(harness.model.hasUnsavedChanges)

        harness.model.discardChanges()

        #expect(!harness.model.hasUnsavedChanges)
        #expect(harness.model.cellEditor == nil && harness.model.useForEditor == nil && harness.model.hiddenAgentsEdit == nil)
    }

    // MARK: use-for

    @Test func aRolesDescriptionIsSavedAsOneKey() async throws {
        let harness = try await Self.harness()
        let revision = await harness.fake.currentRevision

        harness.model.beginUseForEdit(role: "qa")
        harness.model.setUseForText("run the tests")
        await harness.model.saveUseFor()

        let writes = await Self.writes(harness.fake)
        #expect(writes.first?.write == .useFor(role: "qa", text: "run the tests"))
        #expect(writes.first?.ifMatch == revision)
        #expect(harness.model.useForEditor == nil)
        #expect(harness.model.matrix.rows.first { $0.role.name == "qa" }?.role.useFor == "run the tests")
    }

    @Test func anUndeclaredRoleHasNoDescriptionToEdit() async throws {
        let document = LeoDelegationDocument(
            revision: "seed", activeProfile: "p", templates: LeoDelegationFixtures.templates, roles: [LeoDelegationRole(name: "ghost", declared: false)],
            profiles: [LeoDelegationProfile(name: "p", active: true, roles: ["ghost": LeoDelegationCell(template: "coder")])]
        )
        let harness = try await Self.harness(document)

        harness.model.beginUseForEdit(role: "ghost")

        #expect(harness.model.useForEditor == nil)
    }

    @Test func aDescriptionEditedWhileAnotherWriterMovedOnConflictsAndOverwriteResendsOnlyTheText() async throws {
        let harness = try await Self.harness()
        harness.model.beginUseForEdit(role: "qa")
        harness.model.setUseForText("run the tests")
        await harness.fake.externalDelegationChange(profile: "deep", role: "coder", target: LeoDelegationTarget(template: "reviewer"))

        await harness.model.saveUseFor()
        #expect(harness.model.conflict != nil)
        await harness.model.overwrite()

        #expect(harness.model.matrix.rows.first { $0.role.name == "qa" }?.role.useFor == "run the tests")
        #expect(harness.model.matrix.cell(profile: "deep", role: "coder")?.template == "reviewer")
    }

    // MARK: hidden agents

    @Test func hiddenAgentsAreSavedAsTheWholeListAndAnEmptyListHidesNone() async throws {
        let harness = try await Self.harness()
        harness.model.setHiddenAgents(["Explore", "Plan"])
        await harness.model.saveHiddenAgents()
        harness.model.setHiddenAgents([])
        await harness.model.saveHiddenAgents()

        let writes = await Self.writes(harness.fake)
        #expect(writes.map(\.write) == [.hideAgents(["Explore", "Plan"]), .hideAgents([])])
        #expect(harness.model.document?.hideNativeAgents == [])
        #expect(harness.model.hiddenAgentsEdit == nil)
    }

    @Test func theHideListShowsTheEditUntilItIsSaved() async throws {
        let harness = try await Self.harness()
        let original = harness.model.hiddenAgentNames

        harness.model.setHiddenAgents(["Only"])
        #expect(harness.model.hiddenAgentNames == ["Only"])
        harness.model.revertHiddenAgents()

        #expect(harness.model.hiddenAgentNames == original)
        #expect(!harness.model.hasUnsavedChanges)
    }

    @Test func blankHideEntriesAreDroppedOnSave() async throws {
        let harness = try await Self.harness()

        harness.model.setHiddenAgents(["Explore", " ", ""])
        await harness.model.saveHiddenAgents()

        #expect(await Self.writes(harness.fake).first?.write == .hideAgents(["Explore"]))
    }

    @Test func reloadingAfterAnotherWriterAddedAHiddenAgentKeepsTheirAdditionAndTheUsersRemoval() async throws {
        let harness = try await Self.harness()
        let original = try #require(harness.model.document?.hideNativeAgents)
        harness.model.setHiddenAgents(original.filter { $0 != "Plan" })
        _ = try await harness.fake.setHiddenAgents(original + ["Explore2"], ifMatch: await harness.fake.currentRevision)

        await harness.model.saveHiddenAgents()
        #expect(harness.model.conflict != nil)
        await harness.model.reloadAfterConflict()
        #expect(harness.model.hiddenAgentNames == original.filter { $0 != "Plan" } + ["Explore2"])
        await harness.model.saveHiddenAgents()

        #expect(try await harness.fake.delegation().hideNativeAgents == original.filter { $0 != "Plan" } + ["Explore2"])
    }

    @Test func overwritingTheHideListResendsTheUsersDiffOverTheCurrentList() async throws {
        let harness = try await Self.harness()
        let original = try #require(harness.model.document?.hideNativeAgents)
        harness.model.setHiddenAgents(original.filter { $0 != "Plan" })
        _ = try await harness.fake.setHiddenAgents(original + ["Explore2"], ifMatch: await harness.fake.currentRevision)

        await harness.model.saveHiddenAgents()
        await harness.model.overwrite()

        #expect(try await harness.fake.delegation().hideNativeAgents == original.filter { $0 != "Plan" } + ["Explore2"])
    }

    @Test func overwritingACellAnotherWriterDeletedKeepsTheUsersEditedCell() async throws {
        let harness = try await Self.harness()
        harness.model.beginCellEdit(profile: "deep", role: "coder")
        harness.model.setCellEffort("high")
        await harness.fake.externalDelegationChange(profile: "deep", role: "coder", target: LeoDelegationTarget())
        await harness.model.saveCellEdit()
        #expect(harness.model.conflict != nil)

        await harness.model.overwrite()

        let cell = try #require(try await harness.fake.delegation().profiles.first { $0.name == "deep" }?.roles["coder"])
        #expect(cell.template == "coder" && cell.effort == "high")
        #expect(harness.model.cellEditor == nil)
    }

    // MARK: active profile

    @Test func makingAProfileActiveShowsThePreviewThenWritesAfterConfirming() async throws {
        let harness = try await Self.harness()
        let revision = await harness.fake.currentRevision

        await harness.model.requestActivate("deep")
        guard case .loaded(let preview)? = harness.model.preview else {
            Issue.record("Expected a loaded preview")
            return
        }
        #expect(preview.profile == "deep")
        #expect(preview.changes.map(\.role) == ["coder", "qa"])
        #expect(await Self.writeCount(harness.fake) == 0)
        await harness.model.confirmActivate()

        #expect(await Self.writes(harness.fake).map(\.write) == [.active("deep")])
        #expect(await Self.writes(harness.fake).first?.ifMatch == revision)
        #expect(harness.model.preview == nil)
        #expect(harness.model.document?.activeProfile == "deep")
    }

    @Test func cancellingThePreviewWritesNothing() async throws {
        let harness = try await Self.harness()

        await harness.model.requestActivate("deep")
        harness.model.cancelPreview()
        await harness.model.confirmActivate()

        #expect(harness.model.preview == nil)
        #expect(await Self.writeCount(harness.fake) == 0)
    }

    @Test func theActiveProfileIsNotPreviewedAgain() async throws {
        let harness = try await Self.harness()

        await harness.model.requestActivate("fast")

        #expect(harness.model.preview == nil)
        #expect(await harness.fake.calls.contains { if case .delegationPreview = $0 { true } else { false } } == false)
    }

    @Test func aPreviewThatCouldNotBeReadOffersARetryNotAWrite() async throws {
        let harness = try await Self.harness()
        await harness.fake.failNextRead(with: LeoDaemonError.transport("tunnel down"))

        await harness.model.requestActivate("deep")

        guard case .failed(let profile, _)? = harness.model.preview else {
            Issue.record("Expected a failed preview")
            return
        }
        #expect(profile == "deep")
        await harness.model.confirmActivate()
        #expect(await Self.writeCount(harness.fake) == 0)
    }

    @Test func aStalePreviewReplyAfterCancellingNeverReopensTheDialog() async throws {
        let harness = try await Self.harness()
        await harness.fake.holdReads()

        let request = Task { await harness.model.requestActivate("deep") }
        while await harness.fake.heldReadCount == 0 { await Task.yield() }
        harness.model.cancelPreview()
        await harness.fake.releaseReads()
        await request.value

        #expect(harness.model.preview == nil)
    }

    @Test func aConflictOnActivatingOffersReloadAndOverwriteResendsTheActivation() async throws {
        let harness = try await Self.harness()
        await harness.model.requestActivate("deep")
        await harness.fake.externalChange("web", values: [:])

        await harness.model.confirmActivate()
        #expect(harness.model.conflict != nil)
        #expect(harness.model.document?.activeProfile == "fast")
        await harness.model.overwrite()

        #expect(harness.model.document?.activeProfile == "deep")
        #expect(harness.model.conflict == nil)
    }

    // MARK: roles and profiles

    @Test func addingARoleSendsItsNameAndTemplate() async throws {
        let harness = try await Self.harness()

        await harness.model.addRole(name: "docs", template: "scout")

        #expect(await Self.writes(harness.fake).map(\.write) == [.addRole(name: "docs", template: "scout")])
        #expect(harness.model.matrix.rows.map(\.role.name) == ["coder", "docs", "qa"])
        #expect(harness.model.matrix.cell(profile: "fast", role: "docs")?.template == "scout")
    }

    @Test func renamingAndDuplicatingAndAddingProfilesWrite() async throws {
        let harness = try await Self.harness()

        await harness.model.addProfile(name: "cheap")
        await harness.model.duplicateProfile("deep", as: "deeper")
        await harness.model.renameProfile("cheap", to: "thrifty")
        await harness.model.renameRole("qa", to: "tester")

        #expect(await Self.writes(harness.fake).map(\.write) == [
            .addProfile("cheap"), .duplicateProfile("deep", as: "deeper"), .renameProfile("cheap", to: "thrifty"), .renameRole("qa", to: "tester"),
        ])
        #expect(harness.model.matrix.profiles.map(\.name) == ["deep", "deeper", "fast", "thrifty"])
        #expect(harness.model.matrix.rows.map(\.role.name) == ["coder", "tester"])
    }

    @Test func deletingARoleAsksFirstAndNamesTheProfilesItIsRemovedFrom() async throws {
        let harness = try await Self.harness()

        harness.model.requestDeleteRole("coder")

        #expect(harness.model.confirmation == .deleteRole(name: "coder", profiles: ["deep", "fast"]))
        #expect(await Self.writeCount(harness.fake) == 0)
        harness.model.cancelConfirmation()
        #expect(harness.model.confirmation == nil)
        #expect(await Self.writeCount(harness.fake) == 0)
    }

    @Test func confirmingADeleteTakesTheConfirmationTheAlertShowed() async throws {
        let harness = try await Self.harness()
        harness.model.requestDeleteRole("qa")
        let asked = try #require(harness.model.confirmation)
        harness.model.cancelConfirmation()

        await harness.model.confirm(asked)

        #expect(await Self.writes(harness.fake).map(\.write) == [.deleteRole("qa")])
        #expect(harness.model.matrix.rows.map(\.role.name) == ["coder"])
    }

    @Test func theLastDeclaredRoleAndTheActiveProfileCantBeDeleted() async throws {
        let harness = try await Self.harness(LeoDelegationFixtures.document(roles: [LeoDelegationRole(name: "coder")]))

        #expect(!harness.model.canDeleteRole("coder"))
        #expect(!harness.model.canDeleteProfile("fast"))
        #expect(harness.model.canDeleteProfile("deep"))
        harness.model.requestDeleteRole("coder")
        harness.model.requestDeleteProfile("fast")
        #expect(harness.model.confirmation == nil)
    }

    @Test func deletingAProfileAsksThenWrites() async throws {
        let harness = try await Self.harness()

        harness.model.requestDeleteProfile("deep")
        #expect(harness.model.confirmation == .deleteProfile(name: "deep", roleCount: 2))
        await harness.model.confirm(try #require(harness.model.confirmation))

        #expect(await Self.writes(harness.fake).map(\.write) == [.deleteProfile("deep")])
        #expect(harness.model.matrix.profiles.map(\.name) == ["fast"])
    }

    @Test func structureWaitsForACleanFormSoNoEditIsLostToARename() async throws {
        let harness = try await Self.harness()
        harness.model.beginCellEdit(profile: "deep", role: "coder")
        harness.model.setCellEffort("high")

        #expect(!harness.model.canRestructure)
        await harness.model.renameRole("coder", to: "writer")
        harness.model.requestDeleteProfile("deep")

        #expect(await Self.writeCount(harness.fake) == 0)
        #expect(harness.model.confirmation == nil)
    }

    @Test func aCleanOpenEditorClosesWhenTheStructureChanges() async throws {
        let harness = try await Self.harness()
        harness.model.beginCellEdit(profile: "deep", role: "coder")

        await harness.model.renameRole("coder", to: "writer")

        #expect(harness.model.cellEditor == nil)
    }

    @Test func namesAreCheckedAgainstTheMachinesPatternAndTheTakenOnes() async throws {
        let harness = try await Self.harness()

        #expect(harness.model.roleNameError("qa") != nil)
        #expect(harness.model.roleNameError("qa", excluding: "qa") == nil)
        #expect(harness.model.roleNameError("has space") != nil)
        #expect(harness.model.roleNameError("docs") == nil)
        #expect(harness.model.profileNameError("deep") != nil)
        #expect(harness.model.profileNameError("cheap") == nil)
    }

    @Test func aRejectedStructuralWriteSaysWhyAndChangesNothing() async throws {
        let harness = try await Self.harness()

        await harness.model.addRole(name: "docs", template: "ghost")

        #expect(harness.model.errorMessage != nil)
        #expect(harness.model.matrix.rows.map(\.role.name) == ["coder", "qa"])
    }

    @Test func aConflictOnARenameReloadsWithoutRepeatingItOrOverwritesWithIt() async throws {
        let harness = try await Self.harness()
        await harness.fake.externalChange("web", values: [:])
        await harness.model.renameProfile("deep", to: "deeper")
        #expect(harness.model.conflict != nil)

        await harness.model.reloadAfterConflict()
        #expect(harness.model.conflict == nil)
        #expect(await Self.writes(harness.fake).count == 1)
        #expect(harness.model.matrix.profiles.map(\.name) == ["deep", "fast"])

        await harness.fake.externalChange("web", values: [:])
        await harness.model.renameProfile("deep", to: "deeper")
        await harness.model.overwrite()
        #expect(harness.model.matrix.profiles.map(\.name) == ["deeper", "fast"])
    }

    @Test func writesAreSerialisedSoASecondOneWhileOneIsInFlightIsDropped() async throws {
        let harness = try await Self.harness()
        await harness.fake.holdWrites()

        let first = Task { await harness.model.addProfile(name: "one") }
        await Self.untilHeld(harness.fake)
        await harness.model.addProfile(name: "two")
        await harness.fake.releaseWrites()
        await first.value

        #expect(await Self.writes(harness.fake).map(\.write) == [.addProfile("one")])
    }
}
