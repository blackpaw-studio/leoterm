import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct TaskSettingsTests {
    typealias Store = TestStore<TaskSettings.State, TaskSettings.Action>

    @MainActor
    struct Harness {
        let store: Store
        let fake: LeoFakeConfigClient
        let revisions: LeoConfigRevisionTracker
        let clock: TestClock<Duration>

        var state: TaskSettings.State { store.state }

        func calls(_ matching: (LeoFakeConfigCall) -> Bool) async -> [LeoFakeConfigCall] {
            await fake.calls.filter(matching)
        }

        func updates() async -> [LeoFakeConfigCall] {
            await calls { if case .update = $0 { true } else { false } }
        }

        func promptSaves() async -> [LeoFakeConfigCall] {
            await calls { if case .saveTaskPrompt = $0 { true } else { false } }
        }
    }

    static let newest = LeoTaskRun(task: "heartbeat", startedAt: Date(timeIntervalSince1970: 1_792_800_000), exitCode: 0, durationMs: 900, logFile: "heartbeat-2.log")
    static let older = LeoTaskRun(task: "heartbeat", startedAt: Date(timeIntervalSince1970: 1_792_700_000), exitCode: 1, durationMs: 400, logFile: "heartbeat-1.log")

    static func taskData() -> LeoFakeTaskData {
        LeoFakeTaskData(
            runs: ["heartbeat": [newest, older]],
            logs: ["heartbeat-2.log": "newest log\n", "heartbeat-1.log": "older log\n"],
            prompts: ["heartbeat.md": "Check in.", "prompts/nightly.md": "Nightly work.", "other.md": "Other."]
        )
    }

    /// The Tasks pane over the golden daemon (`heartbeat` is on, `nightly` is
    /// off), loaded, with `open` selected when given.
    static func harness(open: String? = nil) async throws -> Harness {
        let fake = try ConfigGolden.client(tasks: taskData())
        let revisions = LeoConfigRevisionTracker()
        let clock = TestClock()
        let connection = DaemonConnection(daemon: .dionysus, secrets: DaemonSecrets(token: "t"))
        let store = TestStore(initialState: TaskSettings.State(daemon: .dionysus, connection: connection)) {
            TaskSettings()
        } withDependencies: {
            $0.configClients.client = { _ in fake }
            $0.configClients.revisions = { _ in revisions }
            $0.continuousClock = clock
        }
        store.exhaustivity = .off
        await store.send(.collection(.task))
        await store.receive(\.collection.loaded)
        let harness = Harness(store: store, fake: fake, revisions: revisions, clock: clock)
        if let open { await store.send(.collection(.rowTapped(open))) }
        return harness
    }

    /// Opens the prompt page and waits for the file.
    static func openPrompt(_ harness: Harness) async {
        await harness.store.send(.pageOpened(.prompt))
        await harness.store.receive(\.promptLoaded)
    }

    func item(_ name: String, in harness: Harness) -> LeoConfigItem {
        harness.state.collection.core.items.first { $0.name == name }!
    }

    // MARK: switches

    @Test func toggleShowsAtOnceAndWritesEnabledOnly() async throws {
        let harness = try await Self.harness()
        #expect(harness.state.toggles.isEnabled(item("nightly", in: harness)) == false)

        await harness.store.send(.toggleTapped("nightly", true))
        #expect(harness.state.toggles.isEnabled(item("nightly", in: harness)) == true)
        await harness.store.receive(\.collection.delegate.patchFinished)

        let updates = await harness.updates()
        guard case .update(_, "nightly", let patch, _)? = updates.first else {
            Issue.record("expected one update, got \(updates)")
            return
        }
        #expect(patch == ["enabled": .bool(true)])
        #expect(updates.count == 1)
        #expect(harness.state.toggles.isEnabled(item("nightly", in: harness)) == true)
        #expect(item("nightly", in: harness).values["enabled"]?.boolValue == true)
    }

    @Test func toggleFailureRollsBack() async throws {
        let harness = try await Self.harness()
        await harness.fake.failNextWrite(with: LeoConfigError.invalid([LeoConfigFieldError(field: "enabled", message: "nope")]))

        await harness.store.send(.toggleTapped("nightly", true))
        await harness.store.receive(\.collection.delegate.patchFinished)

        #expect(harness.state.message != nil)
        #expect(harness.state.toggles.isEnabled(item("nightly", in: harness)) == false)
    }

    @Test func togglesRunOneAtATime() async throws {
        let harness = try await Self.harness()
        await harness.fake.holdWrites()

        await harness.store.send(.toggleTapped("nightly", true))
        await harness.store.send(.toggleTapped("heartbeat", false))
        await settle { await harness.fake.heldWriteCount == 1 }
        #expect(await harness.updates().count == 1)
        #expect(harness.state.toggles.isEnabled(item("nightly", in: harness)) == true)
        #expect(harness.state.toggles.isEnabled(item("heartbeat", in: harness)) == false)

        await harness.fake.releaseWrites()
        await harness.store.receive(\.collection.delegate.patchFinished)
        await harness.store.receive(\.collection.delegate.patchFinished)
        #expect(await harness.updates().count == 2)
        #expect(item("nightly", in: harness).values["enabled"]?.boolValue == true)
        #expect(item("heartbeat", in: harness).values["enabled"]?.boolValue == false)
    }

    @Test func toggleRetryKeepsDirtyFormOnItsRevision() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await harness.store.send(.collection(.field("timezone", .string("UTC"))))
        let draftRevision = harness.state.collection.core.draft?.revision
        await harness.fake.externalChange("tasks", name: "nightly", values: ["silent": .bool(true)])

        await harness.store.send(.toggleTapped("nightly", true))
        await harness.store.receive(\.collection.delegate.patchFinished)

        #expect(harness.state.message == nil)
        #expect(item("nightly", in: harness).values["enabled"]?.boolValue == true)
        #expect(harness.state.collection.core.isDirty)
        #expect(harness.state.collection.core.draft?.revision == draftRevision)
        #expect(harness.state.collection.core.revision != draftRevision)
    }

    @Test func savingAfterAToggleRetryStillConflicts() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await harness.store.send(.collection(.field("timezone", .string("UTC"))))
        await harness.fake.externalChange("tasks", name: "nightly", values: ["silent": .bool(true)])
        await harness.store.send(.toggleTapped("nightly", true))
        await harness.store.receive(\.collection.delegate.patchFinished)

        await harness.store.send(.collection(.saveTapped))
        await harness.store.receive(\.collection.writeFinished)

        #expect(harness.state.collection.core.conflict != nil)
        #expect(harness.state.collection.core.isDirty)
    }

    // MARK: Run Now

    @Test func runNowIgnoresASecondPress() async throws {
        let harness = try await Self.harness()
        await harness.fake.holdWrites()

        await harness.store.send(.runNowTapped("heartbeat"))
        await harness.store.send(.runNowTapped("heartbeat"))
        #expect(harness.state.runNotice == .starting("heartbeat"))
        await settle { await harness.fake.heldWriteCount == 1 }
        await harness.fake.releaseWrites()
        await harness.store.receive(\.runFinished)

        #expect(harness.state.runNotice == .started("heartbeat"))
        #expect(await harness.calls { $0 == .runTask("heartbeat") }.count == 1)
    }

    @Test func aLateRunResultNeverLandsOnAnotherTask() async throws {
        let harness = try await Self.harness()
        await harness.fake.holdWrites()
        await harness.store.send(.runNowTapped("heartbeat"))
        await harness.store.send(.runNowTapped("nightly"))
        #expect(harness.state.runNotice == .starting("nightly"))

        await harness.store.send(.runFinished("heartbeat", .success(LeoTaskRunStart(name: "heartbeat", status: "started"))))

        #expect(harness.state.runNotice == .starting("nightly"))
        await harness.fake.releaseWrites()
    }

    // MARK: schedule

    @Test func cronPreviewDebouncesWithTestClock() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await harness.store.send(.collection(.field("schedule", .string("*/5 * * * *"))))
        await harness.clock.advance(by: .milliseconds(200))
        await harness.store.send(.collection(.field("schedule", .string("*/10 * * * *"))))
        await harness.clock.advance(by: .milliseconds(399))
        #expect(await harness.calls { if case .cronPreview = $0 { true } else { false } }.isEmpty)

        await harness.clock.advance(by: .milliseconds(1))
        await harness.store.receive(\.previewed)

        #expect(await harness.calls { if case .cronPreview = $0 { true } else { false } } == [.cronPreview("*/10 * * * *")])
        #expect(harness.state.preview == .valid("Schedule */10 * * * *"))
    }

    @Test func addRequiresASchedule() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.collection(.addTapped))
        await harness.store.send(.collection(.nameEntry(.presented(.textChanged("weekly")))))
        await harness.store.send(.collection(.nameEntry(.presented(.submitTapped))))

        #expect(harness.state.collection.nameEntry?.scheduleError != nil)
        #expect(await harness.calls { if case .add = $0 { true } else { false } }.isEmpty)

        await harness.store.send(.collection(.nameEntry(.presented(.scheduleChanged("0 9 * * 1")))))
        await harness.store.send(.collection(.nameEntry(.presented(.submitTapped))))
        await harness.store.receive(\.collection.writeFinished)

        let adds = await harness.calls { if case .add = $0 { true } else { false } }
        guard case .add(_, "weekly", let values, _)? = adds.first else {
            Issue.record("expected an add, got \(adds)")
            return
        }
        #expect(values == ["schedule": .string("0 9 * * 1")])
        #expect(harness.state.collection.core.items.map(\.name).contains("weekly"))
    }

    // MARK: history and log

    @Test func historyNewestFirstLoadsNewestLog() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await harness.store.send(.pageOpened(.history))
        await harness.store.receive(\.historyLoaded)
        await harness.store.receive(\.logLoaded)

        #expect(harness.state.history == .loaded([Self.newest, Self.older]))
        #expect(harness.state.selectedRun == Self.newest)
        #expect(harness.state.log == .loaded(LeoTaskLog(file: "heartbeat-2.log", text: "newest log\n")))
        #expect(await harness.calls { if case .taskHistory(_, let limit) = $0 { limit == 20 } else { false } }.count == 1)
    }

    @Test func openingAnOlderRunLoadsItsLog() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await harness.store.send(.pageOpened(.history))
        await harness.store.receive(\.historyLoaded)
        await harness.store.receive(\.logLoaded)

        await harness.store.send(.runTapped(Self.older))
        await harness.store.receive(\.logLoaded)

        #expect(harness.state.page == .log)
        #expect(harness.state.log == .loaded(LeoTaskLog(file: "heartbeat-1.log", text: "older log\n")))
    }

    @Test func lateHistoryReplyForOtherTaskDropped() async throws {
        let harness = try await Self.harness(open: "heartbeat")

        await harness.store.send(.historyLoaded("nightly", .success([Self.older])))
        await harness.store.send(.logLoaded("nightly", "nightly-1.log", .success(LeoTaskLog(file: "nightly-1.log", text: "x"))))

        #expect(harness.state.history == .idle)
        #expect(harness.state.selectedRun == nil)
        #expect(harness.state.log == .idle)
    }

    @Test func changingTheSelectionClearsWhatBelongedToTheOldTask() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await harness.store.send(.pageOpened(.history))
        await harness.store.receive(\.historyLoaded)
        await harness.store.receive(\.logLoaded)
        await harness.store.send(.pageOpened(.prompt))
        await harness.store.receive(\.promptLoaded)

        await harness.store.send(.collection(.backTapped))
        await harness.store.send(.collection(.rowTapped("nightly")))

        #expect(harness.state.history == .idle)
        #expect(harness.state.log == .idle)
        #expect(harness.state.prompt.phase == .idle)
        #expect(harness.state.page == nil)
    }

    // MARK: prompt

    @Test func openingThePromptReadsTheConfiguredFile() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await Self.openPrompt(harness)

        #expect(harness.state.prompt.phase == .loaded)
        #expect(harness.state.prompt.text == "Check in.")
        #expect(harness.state.prompt.document?.file == "heartbeat.md")
    }

    @Test func promptSaveSendsTheFilesOwnRevision() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await Self.openPrompt(harness)
        await harness.store.send(.promptTextChanged("Check in twice."))

        await harness.store.send(.promptSaveTapped)
        await harness.store.receive(\.promptSaved)

        #expect(await harness.promptSaves() == [
            .saveTaskPrompt(name: "heartbeat", content: "Check in twice.", ifMatch: LeoTaskPrompt.revision(of: "Check in."))
        ])
        #expect(harness.state.prompt.isDirty == false)
        #expect(harness.state.prompt.document?.content == "Check in twice.")
    }

    @Test func promptSaveRefusedWhenFileMoved() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await Self.openPrompt(harness)
        await harness.store.send(.promptTextChanged("typed for heartbeat.md"))
        await harness.fake.externalChange("tasks", name: "heartbeat", values: ["prompt_file": .string("other.md")])
        await harness.store.send(.collection(.machine(.connectionChanged(true))))
        await harness.store.receive(\.collection.refreshed)

        await harness.store.send(.promptSaveTapped)

        #expect(await harness.promptSaves().isEmpty)
        #expect(harness.state.prompt.confirmation == .fileChanged("other.md"))
        #expect(harness.state.promptDialog != nil)
    }

    @Test func prompt409ReReadsServedFile() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await Self.openPrompt(harness)
        await harness.store.send(.promptTextChanged("mine"))
        await harness.fake.externalPromptChange(file: "heartbeat.md", content: "theirs")

        await harness.store.send(.promptSaveTapped)
        await harness.store.receive(\.promptSaved)
        await harness.store.receive(\.promptConflictChecked)

        #expect(harness.state.prompt.conflict == LeoTaskPrompt.revision(of: "theirs"))
        #expect(harness.state.prompt.text == "mine")
        #expect(await harness.calls { $0 == .taskPrompt("heartbeat") }.count == 2)
    }

    @Test func promptConflictReload() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await Self.openPrompt(harness)
        await harness.store.send(.promptTextChanged("mine"))
        await harness.fake.externalPromptChange(file: "heartbeat.md", content: "theirs")
        await harness.store.send(.promptSaveTapped)
        await harness.store.receive(\.promptSaved)
        await harness.store.receive(\.promptConflictChecked)

        await harness.store.send(.promptReloadTapped)
        await harness.store.receive(\.promptReread)

        #expect(harness.state.prompt.text == "theirs")
        #expect(harness.state.prompt.conflict == nil)
        #expect(harness.state.prompt.isDirty == false)
    }

    @Test func promptConflictOverwrite() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await Self.openPrompt(harness)
        await harness.store.send(.promptTextChanged("mine"))
        await harness.fake.externalPromptChange(file: "heartbeat.md", content: "theirs")
        await harness.store.send(.promptSaveTapped)
        await harness.store.receive(\.promptSaved)
        await harness.store.receive(\.promptConflictChecked)

        await harness.store.send(.promptOverwriteTapped)
        await harness.store.receive(\.promptSaved)

        #expect(await harness.promptSaves().last == .saveTaskPrompt(name: "heartbeat", content: "mine", ifMatch: LeoTaskPrompt.revision(of: "theirs")))
        #expect(harness.state.prompt.conflict == nil)
        #expect(harness.state.prompt.document?.content == "mine")
    }

    @Test func latePromptSaveForAnotherTaskIsDropped() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await Self.openPrompt(harness)
        await harness.store.send(.collection(.backTapped))
        await harness.store.send(.collection(.rowTapped("nightly")))
        await Self.openPrompt(harness)

        await harness.store.send(.promptSaved("heartbeat", "x", leaveAfter: true, .success(LeoTaskPromptWrite(revision: "sha256:z", file: "heartbeat.md"))))

        #expect(harness.state.prompt.document?.file == "prompts/nightly.md")
        #expect(harness.state.page == .prompt)
    }

    @Test func leavingADirtyPromptAsksFirst() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await Self.openPrompt(harness)
        await harness.store.send(.promptTextChanged("typed"))

        await harness.store.send(.promptBackTapped)
        #expect(harness.state.promptLeave != nil)
        #expect(harness.state.page == .prompt)

        await harness.store.send(.promptLeave(.presented(.discard)))
        #expect(harness.state.page == nil)
        #expect(harness.state.prompt.phase == .idle)
    }

    @Test func poppingADirtyPromptKeepsItsText() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await Self.openPrompt(harness)
        await harness.store.send(.promptTextChanged("typed"))

        await harness.store.send(.pagePopped(.prompt))

        #expect(harness.state.page == .prompt)
        #expect(harness.state.prompt.text == "typed")
    }

    @Test func formSaveRepointingPromptAsks() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await Self.openPrompt(harness)
        await harness.store.send(.promptTextChanged("typed for heartbeat.md"))
        await harness.store.send(.collection(.field("prompt_file", .string("other.md"))))

        await harness.store.send(.collection(.saveTapped))
        await harness.store.receive(\.collection.delegate.saveHeld)

        #expect(await harness.updates().isEmpty)
        #expect(harness.state.prompt.confirmation == .saveWithFile("other.md"))
        #expect(harness.state.formSaveDialog != nil)

        await harness.store.send(.formSaveDialog(.presented(.discardPromptAndSave)))
        await harness.store.receive(\.collection.writeFinished)

        #expect(harness.state.prompt.isDirty == false)
        #expect(await harness.updates().count == 1)
    }

    @Test func keepTextWritesNewFile() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await Self.openPrompt(harness)
        await harness.store.send(.promptTextChanged("typed"))
        await harness.fake.externalChange("tasks", name: "heartbeat", values: ["prompt_file": .string("other.md")])
        await harness.store.send(.collection(.machine(.connectionChanged(true))))
        await harness.store.receive(\.collection.refreshed)
        #expect(harness.state.prompt.confirmation == .fileChanged("other.md"))

        await harness.store.send(.promptDialog(.presented(.keepText)))
        await harness.store.receive(\.promptReread)
        await harness.store.receive(\.promptSaved)

        #expect(await harness.promptSaves() == [
            .saveTaskPrompt(name: "heartbeat", content: "typed", ifMatch: LeoTaskPrompt.revision(of: "Other."))
        ])
        #expect(harness.state.prompt.document?.file == "other.md")
        #expect(harness.state.prompt.isDirty == false)
    }

    @Test func discardTextTakesTheNewFile() async throws {
        let harness = try await Self.harness(open: "heartbeat")
        await Self.openPrompt(harness)
        await harness.store.send(.promptTextChanged("typed"))
        await harness.fake.externalChange("tasks", name: "heartbeat", values: ["prompt_file": .string("other.md")])
        await harness.store.send(.collection(.machine(.connectionChanged(true))))
        await harness.store.receive(\.collection.refreshed)

        await harness.store.send(.promptDialog(.presented(.discardText)))
        await harness.store.receive(\.promptReread)

        #expect(harness.state.prompt.text == "Other.")
        #expect(await harness.promptSaves().isEmpty)
    }
}

/// Polls `condition` with short sleeps: a held write is reached from another
/// thread, which `Task.yield` doesn't wait for.
@MainActor
func settle(_ condition: () async -> Bool) async {
    for _ in 0..<400 where !(await condition()) {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
