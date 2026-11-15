import Foundation
import Testing

@testable import LeoKit

struct LeoDelegationListEditTests {
    @Test func anEditRecordsWhatWasAddedAndRemovedAgainstItsBase() {
        var edit = LeoDelegationListEdit(base: ["a", "b", "c"])
        edit.names = ["a", "c", "d"]

        #expect(edit.removed == ["b"])
        #expect(edit.added == ["d"])
        #expect(edit.isDirty)
    }

    @Test func overAnUnchangedListTheEditIsExactlyWhatWasTyped() {
        var edit = LeoDelegationListEdit(base: ["a", "b", "c"])
        edit.names = ["c", "a"]

        #expect(edit.applied(to: ["a", "b", "c"]) == ["c", "a"])
    }

    @Test func overAChangedListOnlyTheUsersAdditionsAndRemovalsAreReplayed() {
        var edit = LeoDelegationListEdit(base: ["a", "b", "c"])
        edit.names = ["a", "c", "d"]

        #expect(edit.applied(to: ["a", "b", "c", "x"]) == ["a", "c", "x", "d"])
    }

    @Test func anAdditionAnotherWriterAlsoMadeIsNotDuplicated() {
        var edit = LeoDelegationListEdit(base: ["a"])
        edit.names = ["a", "d"]

        #expect(edit.applied(to: ["a", "d"]) == ["a", "d"])
    }

    @Test func rebasingKeepsTheDiffOverTheFreshListAndGoesCleanWhenItMatches() {
        var edit = LeoDelegationListEdit(base: ["a", "b"])
        edit.names = ["a"]

        #expect(edit.rebased(onto: ["a", "b", "x"]).names == ["a", "x"])
        #expect(edit.rebased(onto: ["a", "b", "x"]).base == ["a", "b", "x"])
        #expect(!edit.rebased(onto: ["a"]).isDirty)
    }
}
