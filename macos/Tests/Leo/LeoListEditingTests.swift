import Testing
@testable import Ghostty

struct LeoListEditingTests {
    private struct Row: Identifiable, Equatable {
        let id: Int
    }

    @Test func removingAMiddleItemSelectsTheOneThatTookItsPlace() {
        let result = LeoListEditing.remove(at: 1, from: ["a", "b", "c"])
        #expect(result.items == ["a", "c"])
        #expect(result.selection == 1)
    }

    @Test func removingTheLastItemSelectsTheNewLastOne() {
        let result = LeoListEditing.remove(at: 2, from: ["a", "b", "c"])
        #expect(result.items == ["a", "b"])
        #expect(result.selection == 1)
    }

    @Test func removingTheOnlyItemSelectsNothing() {
        let result = LeoListEditing.remove(at: 0, from: ["a"])
        #expect(result.items.isEmpty)
        #expect(result.selection == nil)
    }

    @Test func removingAnIndexOutsideTheListChangesNothing() {
        let result = LeoListEditing.remove(at: 5, from: ["a", "b"])
        #expect(result.items == ["a", "b"])
        #expect(result.selection == nil)
    }

    @Test func removingTheSelectedRowByIdKeepsTheOthersInOrderAndSelectsTheNext() {
        let result = LeoListEditing.remove(20, from: [Row(id: 10), Row(id: 20), Row(id: 30)])
        #expect(result.rows == [Row(id: 10), Row(id: 30)])
        #expect(result.selection == 30)
    }

    @Test func removingTheLastRowByIdSelectsThePreviousOne() {
        let result = LeoListEditing.remove(30, from: [Row(id: 10), Row(id: 20), Row(id: 30)])
        #expect(result.selection == 20)
    }

    @Test func removingWithNothingSelectedChangesNothing() {
        let rows = [Row(id: 10), Row(id: 20)]
        let result = LeoListEditing.remove(nil, from: rows)
        #expect(result.rows == rows)
        #expect(result.selection == nil)
    }

    @Test func removingAnUnknownIdLeavesTheSelectionAlone() {
        let rows = [Row(id: 10)]
        let result = LeoListEditing.remove(99, from: rows)
        #expect(result.rows == rows)
        #expect(result.selection == 99)
    }
}
