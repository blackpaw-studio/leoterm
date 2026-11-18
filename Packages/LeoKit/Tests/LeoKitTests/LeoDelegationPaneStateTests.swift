import Foundation
import Testing

@testable import LeoKit

struct LeoDelegationPaneStateTests {
    static func loaded(_ document: LeoDelegationDocument = LeoDelegationMatrixTests.document()) -> LeoDelegationPaneState {
        var state = LeoDelegationPaneState()
        state.beginLoading()
        state.loaded(LeoDelegationLoad(document: document))
        return state
    }

    private static func sent(
        _ operation: LeoDelegationOperation, readBack: LeoDelegationDocument, rebasing: Set<LeoDelegationEditor> = []
    ) -> LeoDelegationWriteOutcome {
        LeoDelegationWriteOutcome(
            operation: operation, fresh: nil, sentWith: "r1",
            reply: .sent(LeoDelegationWriteResult(revision: readBack.revision, item: readBack), rebasing: rebasing, readBack: readBack)
        )
    }

    @Test func cellEditRefusesUnknownProfileOrRole() {
        var state = Self.loaded()

        state.beginCellEdit(profile: "nope", role: "coder")
        #expect(state.cellEditor == nil)
        state.beginCellEdit(profile: "deep", role: "nope")
        #expect(state.cellEditor == nil)

        state.beginCellEdit(profile: "deep", role: "qa")
        #expect(state.cellEditor?.edit.base == LeoDelegationTarget(template: "reviewer", model: "sonnet", effort: "high"))
        #expect(state.cellEditor?.baseRevision == "r1")
        #expect(!state.hasUnsavedChanges)
    }

    @Test func adoptRebasesOnlyNamedEditors() {
        var state = Self.loaded()
        state.beginCellEdit(profile: "deep", role: "coder")
        state.setCellEffort("high")
        state.setHiddenAgents(["Explore"])
        let fresh = LeoDelegationMatrixTests.document()
        let moved = LeoDelegationDocument(
            revision: "r2", activeProfile: fresh.activeProfile, hideNativeAgents: ["Plan"], templates: fresh.templates, roles: fresh.roles,
            profiles: fresh.profiles
        )

        state.adopt(moved, rebasing: [.cell])

        #expect(state.document?.revision == "r2")
        #expect(state.cellEditor?.baseRevision == "r2")
        #expect(state.cellEditor?.edit.target.effort == "high")
        #expect(state.hiddenAgentsEdit?.baseRevision == "r1")
        #expect(state.hiddenAgentNames == ["Explore"])
    }

    @Test func invalidLandsOnCellFields() {
        var state = Self.loaded()
        state.beginCellEdit(profile: "deep", role: "coder")
        state.setCellModel("bogus")

        state.fail(.cell, LeoConfigError.invalid([LeoConfigFieldError(field: "model", message: "no such model")]))

        #expect(state.cellEditor?.errors["model"] != nil)
        #expect(state.cellEditor?.edit.target.model == "bogus")
        state.setCellModel("opus")
        #expect(state.cellEditor?.errors["model"] == nil)
    }

    @Test func conflictKeepsOperation() {
        var state = Self.loaded()

        state.fail(.enabled(false), LeoConfigError.conflict(currentRevision: "r9"))

        #expect(state.conflict == LeoDelegationConflict(operation: .enabled(false), currentRevision: "r9"))
        let began = state.beginReload()
        #expect(began)
        #expect(state.conflict == nil)
    }

    @Test func structureWaitsForCleanEdits() {
        var state = Self.loaded()
        #expect(state.canRestructure)
        state.beginUseForEdit(role: "coder")
        state.setUseForText("shipping code")

        #expect(!state.canRestructure)
        state.requestDeleteProfile("deep")
        #expect(state.confirmation == nil)

        state.cancelUseForEdit(role: "coder")
        state.requestDeleteProfile("deep")
        #expect(state.confirmation == .deleteProfile(name: "deep", roleCount: 2))
        let taken = state.take(.deleteProfile(name: "deep", roleCount: 2))
        #expect(taken == .deleteProfile("deep"))
        #expect(state.confirmation == nil)
    }

    @Test func lastDeclaredRoleNotDeletable() {
        let state = Self.loaded(LeoDelegationMatrixTests.document(roles: [LeoDelegationRole(name: "coder")]))

        #expect(!state.canDeleteRole("coder"))
        #expect(state.matrix.rows.contains { $0.role.name == "qa" && !$0.role.declared })
        #expect(state.canDeleteRole("qa"))
        #expect(!state.canDeleteRole("nope"))
    }

    @Test func activeProfileNotDeletable() {
        var state = Self.loaded()

        #expect(!state.canDeleteProfile("fast"))
        #expect(state.canDeleteProfile("deep"))
        state.requestDeleteProfile("fast")
        #expect(state.confirmation == nil)
    }

    @Test func structureWriteClosesAllEditors() {
        var state = Self.loaded()
        state.beginCellEdit(profile: "deep", role: "coder")
        state.beginUseForEdit(role: "qa")

        let began = state.beginWrite(.addProfile("cheap"))
        #expect(began)
        #expect(state.isBusy)
        state.finishWrite(Self.sent(.addProfile("cheap"), readBack: LeoDelegationMatrixTests.document()))

        #expect(state.cellEditor == nil)
        #expect(state.useForEditor == nil)
        #expect(!state.isBusy)
        #expect(state.restartPrompt == nil)
    }

    @Test func enabledReadsAsPendingUntilTheWriteAnswers() {
        var state = Self.loaded()

        _ = state.beginWrite(.enabled(false))
        #expect(state.displayedEnabled == false)
        #expect(state.document?.enabled == true)
        let refused = !state.beginWrite(.enabled(true))
        #expect(refused)

        state.finishWrite(LeoDelegationWriteOutcome(
            operation: .enabled(false), fresh: nil, sentWith: "r1", reply: .failed(LeoDaemonError.transport("down"))
        ))
        #expect(state.displayedEnabled == true)
        #expect(state.errorMessage != nil)
    }

    @Test func previewForAnotherProfileIsDropped() {
        var state = Self.loaded()
        let first = state.beginPreview("deep")
        let second = state.beginPreview("fast")
        #expect(first)
        #expect(!second)

        state.finishPreview(.loaded(LeoDelegationPreview(profile: "other")), for: "other")
        #expect(state.preview == .loading("deep"))
        state.finishPreview(.loaded(LeoDelegationPreview(profile: "deep")), for: "deep")
        let confirmed = state.confirmActivate()
        #expect(confirmed == .activate("deep"))
        #expect(state.preview == nil)
    }
}
