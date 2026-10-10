import Foundation
import Testing

@testable import Ghostty

/// B-283: the one ordered-list value behind the spawn sheet, the Set
/// Environments submenu and the Edit Order sheet.
struct LeoEnvironmentListTests {
    private let list = LeoEnvironmentList(["b", "a", "c"])

    @Test func togglingOnAppendsAndOffRemoves() {
        #expect(list.toggling("z").names == ["b", "a", "c", "z"])
        #expect(list.toggling("a").names == ["b", "c"])
    }

    @Test func addIgnoresDuplicates() {
        #expect(list.adding("a") == list)
        #expect(list.adding("d").names == ["b", "a", "c", "d"])
    }

    @Test func movesAndRemoves() {
        #expect(list.moving("a", by: -1).names == ["a", "b", "c"])
        #expect(list.moving("a", by: 1).names == ["b", "c", "a"])
        #expect(list.moving("b", by: -1) == list)
        #expect(list.moving("c", by: 1) == list)
        #expect(list.moving(fromOffsets: IndexSet(integer: 2), toOffset: 0).names == ["c", "b", "a"])
        #expect(list.removing("b").names == ["a", "c"])
    }

    @Test func addableNamesAreAlphabeticalAndUnused() {
        #expect(list.addable(from: ["z", "a", "m", "b"]) == ["m", "z"])
    }
}

struct LeoEnvironmentMenuTests {
    private let catalog = LeoEnvironmentCatalog(names: ["prod", "aws", "dev"])

    @Test func placeholders() {
        #expect(LeoEnvironmentMenu.entries(catalog: .loading, current: nil).first == .placeholder("Loading…"))
        #expect(LeoEnvironmentMenu.entries(catalog: .failed("HTTP 404"), current: nil).first == .placeholder("Environments Unavailable: HTTP 404"))
        let none = LeoEnvironmentMenu.entries(catalog: .loaded(LeoEnvironmentCatalog(names: [])), current: nil)
        #expect(none.first == .placeholder("No Environments"))
    }

    @Test func checkmarksEffectiveNamesThenEditOrderThenReset() {
        let current = LeoAgentEnvironments(names: ["prod", "gone"], source: .override, error: "gone is missing")
        let entries = LeoEnvironmentMenu.entries(catalog: .loaded(catalog), current: current)
        #expect(entries == [
            .toggle(name: "aws", isOn: false), .toggle(name: "dev", isOn: false), .toggle(name: "prod", isOn: true),
            .toggle(name: "gone", isOn: true),
            .separator, .editOrder(isEnabled: true), .reset(isEnabled: true),
        ])
    }

    @Test func resetOnlyForAnOverride() {
        let fallback = LeoAgentEnvironments(names: ["aws"], source: .default, error: nil)
        #expect(LeoEnvironmentMenu.entries(catalog: .loaded(catalog), current: fallback).last == .reset(isEnabled: false))
        #expect(LeoEnvironmentMenu.entries(catalog: .loading, current: nil).suffix(2) == [.editOrder(isEnabled: false), .reset(isEnabled: false)])
    }
}

struct LeoEnvironmentConfirmationTests {
    @Test func messageSaysRestartAndResume() {
        let set = LeoEnvironmentConfirmation(agent: "alpha", names: ["aws", "prod"])
        #expect(set.title == "Restart “alpha” with new environments?")
        #expect(set.message == "alpha restarts and resumes its session with: aws, prod.")
        #expect(set.confirmTitle == "Restart and Resume")
        let reset = LeoEnvironmentConfirmation(agent: "alpha", names: [])
        #expect(reset.message == "alpha restarts and resumes its session with its template’s default environments.")
    }
}
