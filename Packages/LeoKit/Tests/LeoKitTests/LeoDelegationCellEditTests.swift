import Foundation
import Testing

@testable import LeoKit

struct LeoDelegationCellEditTests {
    private static let base = LeoDelegationTarget(template: "coder", model: "opus", effort: "")

    @Test func aFreshEditIsCleanAndSendsTheCellAsItIs() {
        let edit = LeoDelegationCellEdit(base: Self.base)

        #expect(!edit.isDirty)
        #expect(edit.changedKeys.isEmpty)
        #expect(edit.merged(onto: Self.base) == Self.base)
    }

    @Test func onlyTheEditedKeysAreCarriedOverTheFreshCell() {
        var edit = LeoDelegationCellEdit(base: Self.base)
        edit.target.effort = "high"
        let fresh = LeoDelegationTarget(template: "reviewer", model: "haiku", effort: "")

        #expect(edit.isDirty)
        #expect(edit.changedKeys == [.effort])
        #expect(edit.merged(onto: fresh) == LeoDelegationTarget(template: "reviewer", model: "haiku", effort: "high"))
    }

    @Test func aTemplateAndModelEditAreBothCarried() {
        var edit = LeoDelegationCellEdit(base: Self.base)
        edit.target.template = "reviewer"
        edit.target.model = ""
        let fresh = LeoDelegationTarget(template: "coder", model: "opus", effort: "max")

        #expect(edit.changedKeys == [.template, .model])
        #expect(edit.merged(onto: fresh) == LeoDelegationTarget(template: "reviewer", model: "", effort: "max"))
    }

    @Test func aCellThatWasUnmappedStartsFromAnEmptyBase() {
        var edit = LeoDelegationCellEdit(base: nil)
        edit.target.template = "coder"

        #expect(edit.base == LeoDelegationTarget())
        #expect(edit.changedKeys == [.template])
        #expect(edit.merged(onto: nil) == LeoDelegationTarget(template: "coder"))
    }

    @Test func rebasingKeepsTheEditedKeysAndTakesTheRestFromTheFreshCell() {
        var edit = LeoDelegationCellEdit(base: Self.base)
        edit.target.effort = "high"
        let fresh = LeoDelegationTarget(template: "reviewer", model: "haiku", effort: "low")

        let rebased = edit.rebased(onto: fresh)

        #expect(rebased.base == fresh)
        #expect(rebased.target == LeoDelegationTarget(template: "reviewer", model: "haiku", effort: "high"))
        #expect(rebased.changedKeys == [.effort])
    }

    @Test func rebasingOntoAnEditThatMatchesTheFreshCellIsClean() {
        var edit = LeoDelegationCellEdit(base: Self.base)
        edit.target.effort = "high"

        #expect(!edit.rebased(onto: LeoDelegationTarget(template: "coder", model: "opus", effort: "high")).isDirty)
    }

    @Test func rebasingOntoACellThatWasDeletedKeepsTheEditAgainstAnEmptyBase() {
        var edit = LeoDelegationCellEdit(base: Self.base)
        edit.target.effort = "high"

        let rebased = edit.rebased(onto: nil)

        #expect(rebased.base == LeoDelegationTarget())
        #expect(rebased.target == LeoDelegationTarget(template: "coder", model: "opus", effort: "high"))
    }

    @Test func clearingTheTemplateDeletesTheCell() {
        var edit = LeoDelegationCellEdit(base: Self.base)
        edit.target.template = ""

        #expect(edit.deletesCell)
        #expect(!LeoDelegationCellEdit(base: Self.base).deletesCell)
    }

    @Test func revertingDropsTheEdit() {
        var edit = LeoDelegationCellEdit(base: Self.base)
        edit.target.model = "sonnet"
        edit.revert()

        #expect(!edit.isDirty)
    }
}
