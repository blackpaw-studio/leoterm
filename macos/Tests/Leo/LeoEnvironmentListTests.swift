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

struct LeoEnvironmentSwitchMenuTests {
    private let catalog = LeoEnvironmentCatalog(names: ["aws", "dev", "prod"])

    private func entries(_ current: [String]?, source: LeoAgentEnvironments.Source = .override) -> [LeoEnvironmentMenuEntry] {
        LeoEnvironmentSwitchMenu.entries(
            catalog: .loaded(catalog), current: current.map { LeoAgentEnvironments(names: $0, source: source, error: nil) }
        )
    }

    @Test func listsEveryConfiguredEnvironmentUnchecked() {
        #expect(entries(["aws", "prod"]) == [
            .switchTo(name: "aws", isCurrent: false), .switchTo(name: "dev", isCurrent: false), .switchTo(name: "prod", isCurrent: false),
        ])
    }

    @Test func checksOnlyAnExactlySoleEnvironment() {
        #expect(entries(["dev"]).map(\.isCurrentSwitch) == [false, true, false])
        #expect(entries(["dev", "prod"]).allSatisfy { !$0.isCurrentSwitch })
        #expect(entries([]).allSatisfy { !$0.isCurrentSwitch })
        #expect(entries(nil).allSatisfy { !$0.isCurrentSwitch })
    }

    @Test func templateDefaultSoleEnvironmentCountsAsCurrent() {
        #expect(entries(["prod"], source: .default).map(\.isCurrentSwitch) == [false, false, true])
    }

    @Test func placeholdersMatchTheToggleSubmenu() {
        #expect(LeoEnvironmentSwitchMenu.entries(catalog: .loading, current: nil) == [.placeholder("Loading…")])
        #expect(LeoEnvironmentSwitchMenu.entries(catalog: .failed("HTTP 404"), current: nil) == [.placeholder("Environments Unavailable: HTTP 404")])
        #expect(LeoEnvironmentSwitchMenu.entries(catalog: .loaded(LeoEnvironmentCatalog(names: [])), current: nil) == [.placeholder("No Environments")])
    }
}

@MainActor struct LeoEnvironmentChangeTargetTests {
    private func row(_ names: [String]?) -> LeoAgentRow {
        LeoAgentRow(host: .local, name: "alpha", template: "claude", status: .running, activity: .unknown, actionDetail: nil)
            .withEnvironments(names.map { LeoAgentEnvironments(names: $0, source: .override, error: nil) })
    }

    @Test func switchReplacesTheWholeListWithTheOneName() {
        #expect(LeoEnvironmentChange.targetNames(for: .switchTo(name: "dev", isCurrent: false), row: row(["aws", "prod"])) == ["dev"])
    }

    @Test func switchToTheSoleEnvironmentIsANoOp() {
        #expect(LeoEnvironmentChange.targetNames(for: .switchTo(name: "dev", isCurrent: true), row: row(["dev"])) == nil)
    }

    @Test func switchIgnoresAStaleCurrentFlag() {
        #expect(LeoEnvironmentChange.targetNames(for: .switchTo(name: "dev", isCurrent: false), row: row(["dev"])) == nil)
    }

    @Test func toggleAndResetKeepTheirTargets() {
        #expect(LeoEnvironmentChange.targetNames(for: .toggle(name: "prod", isOn: false), row: row(["aws"])) == ["aws", "prod"])
        #expect(LeoEnvironmentChange.targetNames(for: .reset(isEnabled: true), row: row(["aws"])) == [])
        #expect(LeoEnvironmentChange.targetNames(for: .separator, row: row(["aws"])) == nil)
    }
}

private extension LeoEnvironmentMenuEntry {
    var isCurrentSwitch: Bool {
        if case .switchTo(_, let isCurrent) = self { return isCurrent }
        return false
    }
}
