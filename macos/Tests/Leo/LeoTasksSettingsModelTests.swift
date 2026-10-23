import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor struct LeoTasksSettingsModelTests {
    private struct Harness {
        let model: LeoTasksSettingsModel
        let fake: LeoFakeConfigClient
    }

    private static func harness(page: LeoTasksSettingsModel.Page = .settings, protectedPrompts: Set<String> = []) async throws -> Harness {
        let fake = try LeoConfigGolden.client(tasks: LeoConfigGolden.taskData(protectedPrompts: protectedPrompts))
        let previewer = LeoCronPreviewer(sleep: { _ in }, fetch: { try await fake.cronPreview($0) })
        let model = LeoTasksSettingsModel(client: fake, revisions: LeoConfigRevisionTracker(), machineHost: "dionysus", previewer: previewer)
        await model.load()
        if page != .settings { model.setPage(page) }
        await model.settled()
        return Harness(model: model, fake: fake)
    }

    private static func updates(_ fake: LeoFakeConfigClient) async -> [LeoFakeConfigCall] {
        await fake.calls.filter { if case .update = $0 { true } else { false } }
    }

    private static func count(_ fake: LeoFakeConfigClient, _ matches: (LeoFakeConfigCall) -> Bool) async -> Int {
        await fake.calls.filter(matches).count
    }

    // MARK: loading

    @Test func loadingListsTheTasksAndOffersTheTemplatesToTheTemplateField() async throws {
        let harness = try await Self.harness()

        #expect(harness.model.collection.items.map(\.name) == ["heartbeat", "nightly"])
        #expect(harness.model.collection.selection == "heartbeat")
        let template = harness.model.collection.sections.flatMap(\.rows).first { $0.path == "template" }
        guard case .referencePicker(_, let names, _)? = template?.control else {
            Issue.record("Expected a reference picker for template")
            return
        }
        #expect(names == ["coder", "reviewer"])
    }

    // MARK: enabled toggle

    @Test func theToggleSendsOnlyEnabledAndTheListFollowsTheDaemon() async throws {
        let harness = try await Self.harness()
        let revision = try #require(harness.model.collection.draft?.revision)
        let nightly = try #require(harness.model.collection.items.first { $0.name == "nightly" })
        #expect(!harness.model.isEnabled(nightly))

        await harness.model.setEnabled(true, for: "nightly")

        #expect(await Self.updates(harness.fake) == [
            .update(resource: "tasks", name: "nightly", patch: ["enabled": .bool(true)], ifMatch: revision),
        ])
        #expect(harness.model.collection.items.first { $0.name == "nightly" }.map(harness.model.isEnabled) == true)
        #expect(harness.model.message == nil)
    }

    @Test func aFailedToggleRollsBackAndSaysWhy() async throws {
        let harness = try await Self.harness()
        await harness.fake.failNextWrite(with: LeoDaemonError.daemon(code: "internal", message: "disk full", matches: []))

        await harness.model.setEnabled(true, for: "nightly")

        let nightly = try #require(harness.model.collection.items.first { $0.name == "nightly" })
        #expect(!harness.model.isEnabled(nightly))
        #expect(harness.model.message != nil)
    }

    @Test func aToggleShowsTheNewValueWhileTheRequestIsInFlight() async throws {
        let harness = try await Self.harness()
        let nightly = try #require(harness.model.collection.items.first { $0.name == "nightly" })
        await harness.fake.holdWrites()

        let toggle = Task { await harness.model.setEnabled(true, for: "nightly") }
        while await harness.fake.heldWriteCount == 0 { await Task.yield() }
        #expect(harness.model.isEnabled(nightly))

        await harness.fake.releaseWrites()
        await toggle.value
        #expect(harness.model.collection.items.first { $0.name == "nightly" }.map(harness.model.isEnabled) == true)
    }

    @Test func aToggleKeepsTheOpenFormEdits() async throws {
        let harness = try await Self.harness()
        harness.model.collection.set("model", .string("opus"))

        await harness.model.setEnabled(true, for: "nightly")

        #expect(harness.model.collection.selection == "heartbeat")
        #expect(harness.model.collection.draft?.value(at: "model") == .string("opus"))
        #expect(harness.model.collection.isDirty)
        let patches = await Self.updates(harness.fake)
        #expect(patches.count == 1)
    }

    @Test func aToggleOverAnotherWritersChangeRetriesOnceWithTheCurrentRevision() async throws {
        let harness = try await Self.harness()
        await harness.fake.externalChange("tasks", name: "heartbeat", values: ["owner": .string("evan")])

        await harness.model.setEnabled(true, for: "nightly")

        #expect(await Self.updates(harness.fake).count == 2)
        #expect(harness.model.message == nil)
        #expect(harness.model.collection.items.first { $0.name == "nightly" }.map(harness.model.isEnabled) == true)
    }

    @Test func aRetriedToggleDoesNotHideAnotherWritersChangeFromTheOpenForm() async throws {
        let harness = try await Self.harness()
        harness.model.collection.set("schedule", .string("0 5 * * *"))
        await harness.fake.externalChange("tasks", name: "heartbeat", values: ["schedule": .string("0 9 * * *")])

        await harness.model.setEnabled(true, for: "nightly")
        await harness.model.collection.save()

        #expect(harness.model.collection.conflict != nil)
        #expect(harness.model.collection.draft?.value(at: "schedule") == .string("0 5 * * *"))
        let stored = try await harness.fake.collection("tasks").items.first { $0.name == "heartbeat" }
        #expect(stored?.values["schedule"] == .string("0 9 * * *"))
    }

    @Test func togglingAgainAfterARetriedToggleStillLeavesTheFormAConflict() async throws {
        let harness = try await Self.harness()
        harness.model.collection.set("schedule", .string("0 5 * * *"))
        await harness.fake.externalChange("tasks", name: "heartbeat", values: ["schedule": .string("0 9 * * *")])

        await harness.model.setEnabled(true, for: "nightly")
        await harness.model.setEnabled(false, for: "nightly")
        await harness.model.collection.save()

        #expect(harness.model.collection.conflict != nil)
        let stored = try await harness.fake.collection("tasks").items.first { $0.name == "heartbeat" }
        #expect(stored?.values["schedule"] == .string("0 9 * * *"))
    }

    @Test func aToggleWhileASaveIsRunningSaysSoAndRollsBack() async throws {
        let harness = try await Self.harness()
        harness.model.collection.set("model", .string("opus"))
        await harness.fake.holdWrites()
        let saving = Task { await harness.model.collection.save() }
        while await harness.fake.heldWriteCount == 0 { await Task.yield() }

        await harness.model.setEnabled(true, for: "nightly")
        await harness.fake.releaseWrites()
        await saving.value

        let nightly = try #require(harness.model.collection.items.first { $0.name == "nightly" })
        #expect(!harness.model.isEnabled(nightly))
        #expect(harness.model.message != nil)
        #expect(await Self.updates(harness.fake).count == 1)
    }

    // MARK: run now

    @Test func runNowStartsTheTaskAndSaysSo() async throws {
        let harness = try await Self.harness()

        await harness.model.runNow("heartbeat")

        #expect(await harness.fake.calls.contains(.runTask("heartbeat")))
        #expect(harness.model.runNotice == .started("heartbeat"))
    }

    @Test func aSecondRunNowWhileStartingSendsNothing() async throws {
        let harness = try await Self.harness()
        await harness.fake.holdWrites()
        let first = Task { await harness.model.runNow("heartbeat") }
        while await harness.fake.heldWriteCount == 0 { await Task.yield() }

        let second = Task { await harness.model.runNow("heartbeat") }
        for _ in 0..<20 { await Task.yield() }
        await harness.fake.releaseWrites()
        await first.value
        await second.value

        #expect(await Self.count(harness.fake) { if case .runTask = $0 { true } else { false } } == 1)
        #expect(harness.model.runNotice == .started("heartbeat"))
    }

    @Test func aRunThatCannotStartSaysWhy() async throws {
        let harness = try await Self.harness()
        await harness.fake.failNextWrite(with: LeoDaemonError.daemon(code: "internal", message: "starting task: no leo", matches: []))

        await harness.model.runNow("heartbeat")

        guard case .failed("heartbeat", let reason)? = harness.model.runNotice else {
            Issue.record("Expected a failed notice, got \(String(describing: harness.model.runNotice))")
            return
        }
        #expect(reason.contains("starting task"))
    }

    @Test func theRunNoticeGoesWhenAnotherTaskIsSelected() async throws {
        let harness = try await Self.harness()
        await harness.model.runNow("heartbeat")

        harness.model.collection.select("nightly")
        await harness.model.settled()

        #expect(harness.model.runNotice == nil)
    }

    // MARK: history and log

    @Test func historyIsNewestFirstAndOpensTheNewestRunsLog() async throws {
        let harness = try await Self.harness(page: .history)

        guard case .loaded(let runs) = harness.model.history else {
            Issue.record("Expected loaded history")
            return
        }
        #expect(runs.map(\.logFile) == ["heartbeat-300.jsonl", "", "heartbeat-100.jsonl"])
        #expect(harness.model.selectedRunID == "heartbeat-300.jsonl")
        guard case .loaded(let log) = harness.model.log else {
            Issue.record("Expected a loaded log")
            return
        }
        #expect(log.text == "boom\n")
        #expect(log.truncated)
    }

    @Test func selectingAnotherRunLoadsItsLog() async throws {
        let harness = try await Self.harness(page: .history)

        await harness.model.selectRun("heartbeat-100.jsonl")

        guard case .loaded(let log) = harness.model.log else {
            Issue.record("Expected a loaded log")
            return
        }
        #expect(log.text == "fine\n")
        #expect(!log.truncated)
    }

    @Test func aRunThatKeptNoLogAsksForNone() async throws {
        let harness = try await Self.harness(page: .history)
        let logRequests = await Self.count(harness.fake) { if case .taskLog = $0 { true } else { false } }

        let runs = try #require({ if case .loaded(let runs) = harness.model.history { runs } else { nil } }())
        await harness.model.selectRun(runs[1].id)

        #expect(harness.model.log == .idle)
        #expect(await Self.count(harness.fake) { if case .taskLog = $0 { true } else { false } } == logRequests)
    }

    @Test func aLogThatIsGoneIsAFailureNotACrash() async throws {
        let harness = try await Self.harness(page: .history)
        await harness.fake.failNextRead(with: LeoDaemonError.daemon(code: "not_found", message: "log file not found", matches: []))

        await harness.model.selectRun("heartbeat-100.jsonl")

        guard case .failed = harness.model.log else {
            Issue.record("Expected a failed log")
            return
        }
    }

    @Test func aHistoryReplyForTheTaskYouLeftIsDropped() async throws {
        let harness = try await Self.harness()
        await harness.fake.holdReads()
        harness.model.setPage(.history)
        while await harness.fake.heldReadCount == 0 { await Task.yield() }

        harness.model.collection.select("nightly")
        await harness.fake.releaseReads()
        await harness.model.settled()

        guard case .loaded(let runs) = harness.model.history else {
            Issue.record("Expected nightly's history, got \(harness.model.history)")
            return
        }
        #expect(runs.isEmpty)
        #expect(harness.model.selectedRunID == nil)
    }

    // MARK: prompt

    @Test func thePromptIsTheConfiguredFile() async throws {
        let harness = try await Self.harness(page: .prompt)

        #expect(harness.model.prompt.phase == .loaded)
        #expect(harness.model.prompt.document?.file == "heartbeat.md")
        #expect(harness.model.prompt.text == "Check the thing.\n")
        #expect(!harness.model.prompt.isDirty)
        #expect(!harness.model.hasUnsavedChanges)
    }

    @Test func editingThePromptMakesThePaneDirtyAndSavingSendsItsOwnRevision() async throws {
        let harness = try await Self.harness(page: .prompt)
        let revision = try #require(harness.model.prompt.document?.revision)

        harness.model.setPromptText("Check twice.\n")
        #expect(harness.model.prompt.isDirty)
        #expect(harness.model.hasUnsavedChanges)
        await harness.model.savePrompt()

        #expect(await harness.fake.calls.contains(.saveTaskPrompt(name: "heartbeat", content: "Check twice.\n", ifMatch: revision)))
        #expect(!harness.model.prompt.isDirty)
        #expect(harness.model.prompt.document?.revision == LeoTaskPrompt.revision(of: "Check twice.\n"))
        #expect(await Self.updates(harness.fake).isEmpty)
    }

    @Test func aPromptSavedOverSomeoneElsesEditIsAConflictThatKeepsMyText() async throws {
        let harness = try await Self.harness(page: .prompt)
        await harness.fake.externalPromptChange(file: "heartbeat.md", content: "Theirs.\n")
        harness.model.setPromptText("Mine.\n")

        await harness.model.savePrompt()

        #expect(harness.model.prompt.conflict == LeoTaskPrompt.revision(of: "Theirs.\n"))
        #expect(harness.model.prompt.text == "Mine.\n")
        #expect(harness.model.prompt.isDirty)
    }

    @Test func reloadAfterAPromptConflictTakesTheirs() async throws {
        let harness = try await Self.harness(page: .prompt)
        await harness.fake.externalPromptChange(file: "heartbeat.md", content: "Theirs.\n")
        harness.model.setPromptText("Mine.\n")
        await harness.model.savePrompt()

        await harness.model.reloadPrompt()

        #expect(harness.model.prompt.conflict == nil)
        #expect(harness.model.prompt.text == "Theirs.\n")
        #expect(!harness.model.prompt.isDirty)
    }

    @Test func overwriteAfterAPromptConflictSendsMyTextAgainstTheirRevision() async throws {
        let harness = try await Self.harness(page: .prompt)
        await harness.fake.externalPromptChange(file: "heartbeat.md", content: "Theirs.\n")
        harness.model.setPromptText("Mine.\n")
        await harness.model.savePrompt()

        await harness.model.overwritePrompt()

        #expect(await harness.fake.calls.last == .saveTaskPrompt(name: "heartbeat", content: "Mine.\n", ifMatch: LeoTaskPrompt.revision(of: "Theirs.\n")))
        #expect(harness.model.prompt.conflict == nil)
        #expect(!harness.model.prompt.isDirty)
        #expect(try await harness.fake.taskPrompt("heartbeat").content == "Mine.\n")
    }

    @Test func aProtectedPromptFileIsUnavailableWithTheDaemonsReason() async throws {
        let harness = try await Self.harness(page: .prompt, protectedPrompts: ["heartbeat.md"])

        guard case .unavailable(let reason) = harness.model.prompt.phase else {
            Issue.record("Expected unavailable, got \(harness.model.prompt.phase)")
            return
        }
        #expect(reason.contains("heartbeat.md"))
    }

    // MARK: switching the prompt file

    @Test func choosingAnotherFileIsATaskUpdateOfPromptFileThenAPromptRead() async throws {
        let harness = try await Self.harness(page: .prompt)
        let revision = try #require(harness.model.collection.draft?.revision)

        await harness.model.choosePromptFile("notes.md")

        #expect(await Self.updates(harness.fake) == [
            .update(resource: "tasks", name: "heartbeat", patch: ["prompt_file": .string("notes.md")], ifMatch: revision),
        ])
        #expect(harness.model.prompt.document?.file == "notes.md")
        #expect(harness.model.prompt.text == "Notes\n")
    }

    @Test func choosingAFileKeepsTheFormsOtherEdits() async throws {
        let harness = try await Self.harness(page: .prompt)
        harness.model.collection.set("model", .string("opus"))

        await harness.model.choosePromptFile("notes.md")

        #expect(harness.model.collection.draft?.value(at: "model") == .string("opus"))
        #expect(await Self.updates(harness.fake).allSatisfy {
            if case .update(_, _, let patch, _) = $0 { Set(patch.keys) == ["prompt_file"] } else { false }
        })
    }

    @Test func choosingAFileWithUnsavedPromptEditsAsksFirst() async throws {
        let harness = try await Self.harness(page: .prompt)
        harness.model.setPromptText("Unsaved.\n")

        await harness.model.choosePromptFile("notes.md")
        #expect(harness.model.prompt.confirmation == .switchFile("notes.md"))
        #expect(await Self.updates(harness.fake).isEmpty)

        await harness.model.confirmPromptFileSwitch(.switchFile("notes.md"))
        #expect(harness.model.prompt.document?.file == "notes.md")
        #expect(!harness.model.prompt.isDirty)
    }

    @Test func cancellingTheSwitchKeepsTheEdits() async throws {
        let harness = try await Self.harness(page: .prompt)
        harness.model.setPromptText("Unsaved.\n")
        await harness.model.choosePromptFile("notes.md")

        harness.model.cancelPromptFileSwitch()

        #expect(harness.model.prompt.confirmation == nil)
        #expect(harness.model.prompt.text == "Unsaved.\n")
    }

    @Test func aNewPromptFileIsChosenThroughTheSameUpdateAndStartsEmpty() async throws {
        let harness = try await Self.harness(page: .prompt)

        await harness.model.createPromptFile("prompts/heartbeat-2.md")

        #expect(await Self.updates(harness.fake).count == 1)
        #expect(harness.model.prompt.document?.file == "prompts/heartbeat-2.md")
        #expect(harness.model.prompt.text.isEmpty)
        #expect(harness.model.prompt.document?.revision == LeoTaskPrompt.revision(of: ""))
    }

    @Test func aPromptFileOutsideTheWorkspaceIsRefusedWithoutAsking() async throws {
        let harness = try await Self.harness(page: .prompt)

        await harness.model.createPromptFile("../outside.md")

        #expect(harness.model.prompt.error != nil)
        #expect(await Self.updates(harness.fake).isEmpty)
        #expect(harness.model.prompt.document?.file == "heartbeat.md")
    }

    @Test func aDaemonRefusalOfTheNewFileIsShownAndNothingChanges() async throws {
        let harness = try await Self.harness(page: .prompt)
        await harness.fake.failNextWrite(with: LeoConfigError.invalid([LeoConfigFieldError(field: "prompt_file", message: "leo.yaml cannot be a prompt")]))

        await harness.model.createPromptFile("leo.yaml.md")

        #expect(harness.model.prompt.error == "leo.yaml cannot be a prompt")
        #expect(harness.model.prompt.document?.file == "heartbeat.md")
    }

    // MARK: unsaved edits across the pane

    @Test func selectingAnotherTaskWithPromptEditsAsksAndDiscardDropsThem() async throws {
        let harness = try await Self.harness(page: .prompt)
        harness.model.setPromptText("Unsaved.\n")

        harness.model.collection.select("nightly")
        #expect(harness.model.collection.confirmation == .discardChanges(thenSelect: "nightly"))
        #expect(harness.model.collection.selection == "heartbeat")

        await harness.model.collection.confirm()
        await harness.model.settled()
        #expect(harness.model.collection.selection == "nightly")
        #expect(!harness.model.hasUnsavedChanges)
        #expect(harness.model.prompt.document?.file == "prompts/nightly.md")
        #expect(harness.model.prompt.text.isEmpty)
    }

    @Test func discardChangesDropsBothTheFormAndThePromptEdits() async throws {
        let harness = try await Self.harness(page: .prompt)
        harness.model.collection.set("model", .string("opus"))
        harness.model.setPromptText("Unsaved.\n")

        harness.model.discardChanges()

        #expect(!harness.model.hasUnsavedChanges)
        #expect(harness.model.prompt.text == "Check the thing.\n")
    }

    @Test func aReconnectWithPromptEditsKeepsThemAndTheRevisionTheyWereBasedOn() async throws {
        let harness = try await Self.harness(page: .prompt)
        let basedOn = try #require(harness.model.prompt.document?.revision)
        harness.model.setPromptText("Unsaved.\n")
        await harness.fake.externalPromptChange(file: "heartbeat.md", content: "Theirs.\n")

        await harness.model.reload(using: harness.fake)

        #expect(harness.model.prompt.text == "Unsaved.\n")
        #expect(harness.model.prompt.document?.revision == basedOn)
        await harness.model.savePrompt()
        #expect(harness.model.prompt.conflict == LeoTaskPrompt.revision(of: "Theirs.\n"))
    }

    @Test func aReconnectWithACleanPromptReadsItAgain() async throws {
        let harness = try await Self.harness(page: .prompt)
        await harness.fake.externalPromptChange(file: "heartbeat.md", content: "Theirs.\n")

        await harness.model.reload(using: harness.fake)

        #expect(harness.model.prompt.text == "Theirs.\n")
    }

    @Test func savingTheFormWithANewPromptFileReloadsTheCleanPrompt() async throws {
        let harness = try await Self.harness(page: .prompt)
        harness.model.collection.set("prompt_file", .string("notes.md"))

        await harness.model.collection.save()
        await harness.model.settled()

        #expect(harness.model.prompt.document?.file == "notes.md")
        #expect(harness.model.prompt.text == "Notes\n")
    }

    // MARK: a prompt whose file the task left

    private static func isPromptSave(_ call: LeoFakeConfigCall) -> Bool {
        if case .saveTaskPrompt = call { true } else { false }
    }

    /// Unsaved text on heartbeat.md, then the task is pointed at notes.md and the pane reads the list again.
    private static func repointedUnderUnsavedText() async throws -> Harness {
        let harness = try await Self.harness(page: .prompt)
        harness.model.setPromptText("Mine.\n")
        await harness.fake.externalChange("tasks", name: "heartbeat", values: ["prompt_file": .string("notes.md")])
        await harness.model.reload(using: harness.fake)
        return harness
    }

    @Test func unsavedTextIsNotSavedIntoAFileTheTaskMovedTo() async throws {
        let harness = try await Self.repointedUnderUnsavedText()

        #expect(harness.model.prompt.confirmation == .fileChanged("notes.md"))
        await harness.model.savePrompt()
        await harness.model.overwritePrompt()

        #expect(await Self.count(harness.fake, Self.isPromptSave) == 0)
        #expect(harness.model.prompt.text == "Mine.\n")
    }

    @Test func aDaemonConflictOnAMovedFileIsReportedAsTheMoveNotAsAnOverwrite() async throws {
        let harness = try await Self.harness(page: .prompt)
        harness.model.setPromptText("Mine.\n")
        await harness.fake.externalChange("tasks", name: "heartbeat", values: ["prompt_file": .string("notes.md")])

        await harness.model.savePrompt()
        await harness.model.overwritePrompt()

        #expect(harness.model.prompt.confirmation == .fileChanged("notes.md"))
        #expect(harness.model.prompt.conflict == nil)
        #expect(await Self.count(harness.fake, Self.isPromptSave) == 1)
    }

    @Test func keepingMyTextForTheNewFileWritesItAgainstThatFilesRevision() async throws {
        let harness = try await Self.repointedUnderUnsavedText()

        await harness.model.keepPromptTextForNewFile()

        let revision = LeoTaskPrompt.revision(of: "Notes\n")
        #expect(await harness.fake.calls.contains(.saveTaskPrompt(name: "heartbeat", content: "Mine.\n", ifMatch: revision)))
        #expect(harness.model.prompt.document?.file == "notes.md")
        #expect(harness.model.prompt.confirmation == nil)
        #expect(!harness.model.prompt.isDirty)
    }

    @Test func discardingMyTextForTheNewFileReadsThatFile() async throws {
        let harness = try await Self.repointedUnderUnsavedText()

        await harness.model.discardPromptTextForNewFile()

        #expect(harness.model.prompt.document?.file == "notes.md")
        #expect(harness.model.prompt.text == "Notes\n")
        #expect(harness.model.prompt.confirmation == nil)
        #expect(await Self.count(harness.fake, Self.isPromptSave) == 0)
    }

    @Test func theFormsSaveOfANewPromptFileAsksBeforeDroppingPromptText() async throws {
        let harness = try await Self.harness(page: .prompt)
        harness.model.setPromptText("Mine.\n")
        harness.model.collection.set("prompt_file", .string("notes.md"))

        await harness.model.collection.save()
        #expect(harness.model.prompt.confirmation == .saveWithFile("notes.md"))
        #expect(await Self.updates(harness.fake).isEmpty)

        await harness.model.confirmFormSave(.saveWithFile("notes.md"))
        #expect(await Self.updates(harness.fake).count == 1)
        #expect(harness.model.prompt.document?.file == "notes.md")
        #expect(harness.model.prompt.text == "Notes\n")
    }

    /// SwiftUI closes an alert (the `isPresented` setter, which cancels) before it runs the pressed button's action.
    @Test func theAlertsDiscardButtonSavesTheFormAfterTheAlertHasAlreadyClosed() async throws {
        let harness = try await Self.harness(page: .prompt)
        harness.model.setPromptText("Mine.\n")
        harness.model.collection.set("prompt_file", .string("notes.md"))
        await harness.model.collection.save()

        let shown = try #require(harness.model.prompt.confirmation)
        harness.model.cancelPromptFileSwitch()
        await harness.model.confirmFormSave(shown)

        #expect(await Self.updates(harness.fake).count == 1)
        #expect(harness.model.prompt.document?.file == "notes.md")
    }

    @Test func theAlertsDiscardButtonSwitchesFilesAfterTheAlertHasAlreadyClosed() async throws {
        let harness = try await Self.harness(page: .prompt)
        harness.model.setPromptText("Mine.\n")
        await harness.model.choosePromptFile("notes.md")

        let shown = try #require(harness.model.prompt.confirmation)
        harness.model.cancelPromptFileSwitch()
        await harness.model.confirmPromptFileSwitch(shown)

        #expect(harness.model.prompt.document?.file == "notes.md")
        #expect(!harness.model.prompt.isDirty)
    }

    @Test func cancellingTheHeldFormSaveSendsNothingAndKeepsBothEdits() async throws {
        let harness = try await Self.harness(page: .prompt)
        harness.model.setPromptText("Mine.\n")
        harness.model.collection.set("prompt_file", .string("notes.md"))
        await harness.model.collection.save()

        harness.model.cancelPromptFileSwitch()

        #expect(harness.model.prompt.confirmation == nil)
        #expect(await Self.updates(harness.fake).isEmpty)
        #expect(harness.model.prompt.text == "Mine.\n")
        #expect(harness.model.collection.isDirty)
    }

    @Test func theFormsSaveWithoutAPromptFileChangeIsNotHeld() async throws {
        let harness = try await Self.harness(page: .prompt)
        harness.model.setPromptText("Mine.\n")
        harness.model.collection.set("model", .string("opus"))

        await harness.model.collection.save()

        #expect(harness.model.prompt.confirmation == nil)
        #expect(await Self.updates(harness.fake).count == 1)
        #expect(harness.model.prompt.text == "Mine.\n")
    }

    // MARK: schedule preview

    @Test func theScheduleFieldShowsTheDaemonsReadingAsItIsEdited() async throws {
        let harness = try await Self.harness()
        await harness.model.settled()
        #expect(harness.model.schedulePreview == .valid("Schedule 0 * * * *"))

        harness.model.collection.set("schedule", .string("0 3 *"))
        await harness.model.settled()

        #expect(harness.model.schedulePreview == .invalid("expected 5 fields, got 3"))
    }

    @Test func selectingAnotherTaskPreviewsItsSchedule() async throws {
        let harness = try await Self.harness()

        harness.model.collection.select("nightly")
        await harness.model.settled()

        #expect(harness.model.schedulePreview == .valid("Schedule 0 3 * * *"))
    }

    // MARK: add

    @Test func addingATaskSendsItsScheduleAndSelectsIt() async throws {
        let harness = try await Self.harness()
        let revision = try #require(harness.model.collection.draft?.revision)

        await harness.model.add(name: "weekly", schedule: "0 9 * * 1")

        #expect(await harness.fake.calls.contains(.add(resource: "tasks", name: "weekly", values: ["schedule": .string("0 9 * * 1")], ifMatch: revision)))
        #expect(harness.model.collection.selection == "weekly")
        #expect(harness.model.collection.draft?.value(at: "prompt_file") == .string("prompts/weekly.md"))
    }

    @Test func aTaskCannotBeAddedWithoutASchedule() async throws {
        let harness = try await Self.harness()

        await harness.model.add(name: "weekly", schedule: "  ")

        #expect(await Self.count(harness.fake) { if case .add = $0 { true } else { false } } == 0)
    }
}
