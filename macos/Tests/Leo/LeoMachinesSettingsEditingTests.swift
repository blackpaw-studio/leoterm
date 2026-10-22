import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Enable/disable, Revert and Test Connection on the Machines settings
/// model. Nothing here touches a registry: the model's only way to affect
/// live connections is `onSaved`, which fires on a successful Save alone.
@MainActor struct LeoMachinesSettingsEditingTests {
    @Test func disablingAMachineEditsTheDraftAndSaveWritesIt() throws {
        let (model, store, saves) = makeModel(hosts: [.init(name: "work", sshTarget: "evan@work")])
        let id = try #require(model.hosts.first?.id)

        model.setEnabled(false, for: id)

        #expect(model.hosts.first?.isEnabled == false)
        #expect(store.load().first?.isEnabled == true, "the store is untouched until Save")
        #expect(saves.count == 0)

        #expect(model.save())
        #expect(store.load().first?.isEnabled == false)
        #expect(saves.count == 1, "Save asks the registry to reload exactly once")
    }

    @Test func aDisabledMachineStaysSelectableAndCanBeEnabledAgain() throws {
        let (model, _, _) = makeModel(hosts: [.init(name: "work", sshTarget: "evan@work", isEnabled: false)])
        let id = try #require(model.hosts.first?.id)

        model.setEnabled(true, for: id)

        #expect(model.hosts.first?.isEnabled == true)
        #expect(model.selectedID == id)
    }

    @Test func theDraftIsDirtyOnlyWhileItDiffersFromTheStore() throws {
        let (model, _, _) = makeModel(hosts: [.init(name: "work", sshTarget: "evan@work")])
        #expect(!model.isDirty)

        model.updateSelected { .init(id: $0.id, name: "work", sshTarget: "evan@elsewhere") }
        #expect(model.isDirty)

        model.updateSelected { .init(id: $0.id, name: "work", sshTarget: "evan@work") }
        #expect(!model.isDirty, "editing back to the saved value is not a change")

        model.addHost()
        #expect(model.isDirty)
        model.updateSelected { $0.replacing(name: "second", sshTarget: "evan@second") }
        #expect(model.save())
        #expect(!model.isDirty)

        model.updateSelected { $0.replacing(sshTarget: "evan@moved") }
        #expect(model.save(), "a model can save again after its own save")
    }

    @Test func revertDropsEditsAdditionsAndRemovalsAndKeepsTheSelection() throws {
        let (model, store, saves) = makeModel(hosts: [
            .init(name: "alpha", sshTarget: "evan@alpha"), .init(name: "zeta", sshTarget: "evan@zeta"),
        ])
        let zeta = try #require(model.hosts.first { $0.name == "zeta" })
        model.selectedID = zeta.id
        model.updateSelected { .init(id: $0.id, name: "renamed", sshTarget: $0.sshTarget) }
        model.addHost()
        model.selectedID = model.hosts.first { $0.name == "alpha" }?.id
        model.removeSelected()

        model.revert()

        #expect(model.hosts == store.load())
        #expect(!model.isDirty)
        #expect(model.saveError == nil)
        #expect(saves.count == 0, "Revert never reaches the registry")
    }

    @Test func revertAdoptsAnotherWindowsSaveInsteadOfRefusingForever() throws {
        let (model, store, _) = makeModel(hosts: [.init(name: "work", sshTarget: "evan@work")])
        try store.save([.init(name: "work", sshTarget: "evan@work"), .init(name: "extra", sshTarget: "evan@extra")])
        #expect(!model.save(), "a stale draft refuses to overwrite")

        model.revert()

        #expect(model.hosts.map(\.name) == ["extra", "work"])
        model.updateSelected { .init(id: $0.id, name: $0.name, sshTarget: "evan@changed") }
        #expect(model.save(), "after Revert the draft is current again")
    }

    // MARK: Test Connection

    @Test func testingRunsTheTesterOnTheUnsavedDraftAndShowsItsReport() async throws {
        let tester = ScriptedTester(report: .success(version: "0.57.0", statsAdvertised: true))
        let (model, store, saves) = makeModel(hosts: [.init(name: "work", sshTarget: "evan@work")], tester: tester)
        model.updateSelected { .init(id: $0.id, name: $0.name, sshTarget: "evan@draft.lan") }

        await model.testSelected()

        #expect(tester.tested.map(\.sshTarget) == ["evan@draft.lan"], "the draft is tested, not the saved value")
        #expect(model.testReport?.succeeded == true)
        #expect(!model.isTesting)
        #expect(store.load().first?.sshTarget == "evan@work", "testing saves nothing")
        #expect(saves.count == 0, "and never asks the registry to reload")
    }

    @Test func aFailedSshStepFailsTheReportAndLeavesLaterStepsUntested() {
        let report = LeoConnectionTestReport.sshFailed("ssh: connect to host hestia.lan port 2222: Operation timed out")

        #expect(!report.succeeded)
        #expect(report.outcome(for: .ssh) == .failed("ssh: connect to host hestia.lan port 2222: Operation timed out"))
        #expect(report.outcome(for: .daemon) == .notTested)
        #expect(report.outcome(for: .machineStats) == .notTested)
    }

    @Test func aDaemonWithoutStatsStillConnects() {
        let report = LeoConnectionTestReport.success(version: "0.50.0", statsAdvertised: false)

        #expect(report.succeeded, "missing machine_stats is not a failed connection")
        guard case .unavailable = report.outcome(for: .machineStats) else {
            Issue.record("expected an unavailable stats step, got \(report.outcome(for: .machineStats))")
            return
        }
    }

    @Test func editingTheDraftOrChangingSelectionClearsTheReport() async throws {
        let tester = ScriptedTester(report: .success(version: "0.57.0", statsAdvertised: true))
        let (model, _, _) = makeModel(hosts: [
            .init(name: "alpha", sshTarget: "evan@alpha"), .init(name: "zeta", sshTarget: "evan@zeta"),
        ], tester: tester)

        await model.testSelected()
        #expect(model.testReport != nil)
        model.updateSelected { .init(id: $0.id, name: $0.name, sshTarget: "evan@other") }
        #expect(model.testReport == nil, "a result describes the settings that were tested")

        await model.testSelected()
        model.selectedID = model.hosts.last?.id
        #expect(model.testReport == nil)
    }

    @Test func aResultThatArrivesAfterTheUserMovedOnIsDropped() async throws {
        let tester = ScriptedTester(report: .success(version: "0.57.0", statsAdvertised: true), gated: true)
        let (model, _, _) = makeModel(hosts: [
            .init(name: "alpha", sshTarget: "evan@alpha"), .init(name: "zeta", sshTarget: "evan@zeta"),
        ], tester: tester)

        let running = Task { await model.testSelected() }
        await tester.waitUntilStarted()
        #expect(model.isTesting)
        model.selectedID = model.hosts.last?.id
        tester.release()
        await running.value

        #expect(model.testReport == nil, "alpha's result must not show under zeta")
        #expect(!model.isTesting)
    }

    @Test func anInvalidDraftIsNeverTested() async throws {
        let tester = ScriptedTester(report: .success(version: "0.57.0", statsAdvertised: true))
        let (model, _, _) = makeModel(hosts: [.init(name: "work", sshTarget: "evan@work")], tester: tester)
        model.updateSelected { .init(id: $0.id, name: "work", sshTarget: "") }

        await model.testSelected()

        #expect(tester.tested.isEmpty)
        #expect(model.testReport == nil)
    }

    @Test func revertClearsTheReport() async throws {
        let tester = ScriptedTester(report: .success(version: "0.57.0", statsAdvertised: true))
        let (model, _, _) = makeModel(hosts: [.init(name: "work", sshTarget: "evan@work")], tester: tester)
        await model.testSelected()

        model.revert()

        #expect(model.testReport == nil)
    }

    // MARK: Fixtures

    private final class SaveCounter {
        var count = 0
    }

    private func makeModel(
        hosts: [LeoHostConfiguration], tester: ScriptedTester = ScriptedTester(report: .sshFailed("unused"))
    ) -> (LeoMachinesSettingsModel, LeoHostStore, SaveCounter) {
        let store = LeoHostStore(defaults: LeoInMemoryDefaults())
        try? store.save(hosts)
        let saves = SaveCounter()
        let model = LeoMachinesSettingsModel(store: store, tester: tester) { saves.count += 1 }
        return (model, store, saves)
    }
}

/// Answers every test with one canned report; `gated` holds the answer
/// until `release()` so a test can act while a test is in flight.
private final class ScriptedTester: LeoMachineConnectionTesting, @unchecked Sendable {
    private let report: LeoConnectionTestReport
    private let gated: Bool
    private let lock = NSLock()
    private var testedConfigurations: [LeoHostConfiguration] = []
    private var started: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private var gate: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(report: LeoConnectionTestReport, gated: Bool = false) {
        self.report = report
        self.gated = gated
    }

    var tested: [LeoHostConfiguration] { lock.withLock { testedConfigurations } }

    func test(_ configuration: LeoHostConfiguration) async -> LeoConnectionTestReport {
        lock.withLock { testedConfigurations.append(configuration) }
        signalStarted()
        if gated { await awaitRelease() }
        return report
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if hasStarted { return true }
                started = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isReleased = true
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    private func signalStarted() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            hasStarted = true
            defer { started = nil }
            return started
        }
        waiting?.resume()
    }

    private func awaitRelease() async {
        await withCheckedContinuation { continuation in
            let released = lock.withLock { () -> Bool in
                if isReleased { return true }
                gate = continuation
                return false
            }
            if released { continuation.resume() }
        }
    }
}
