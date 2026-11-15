import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct ConfigCollectionTests {
    typealias Store = TestStore<ConfigCollection.State, ConfigCollection.Action>

    struct Harness {
        let store: Store
        let fake: LeoFakeConfigClient
        let revisions: LeoConfigRevisionTracker

        var core: LeoConfigCollectionState { store.state.core }

        func updates() async -> [LeoFakeConfigCall] {
            await fake.calls.filter { if case .update = $0 { true } else { false } }
        }

        func writes() async -> [LeoFakeConfigCall] {
            await fake.calls.filter {
                switch $0 {
                case .update, .add, .rename, .duplicate, .delete: true
                default: false
                }
            }
        }
    }

    /// A pane over the golden daemon, loaded, with `open` selected when given.
    private static func harness(
        resource: String = "templates", open: String? = nil, daemon: PairedDaemon = .dionysus,
        seed: [String: LeoConfigValue] = [:]
    ) async throws -> Harness {
        let fake = try ConfigGolden.client()
        if !seed.isEmpty { await fake.externalChange("templates", name: "coder", values: seed) }
        let revisions = LeoConfigRevisionTracker()
        let connection = DaemonConnection(daemon: daemon, secrets: DaemonSecrets(token: "t"))
        let store = TestStore(initialState: ConfigCollection.State(resource: resource, daemon: daemon, connection: connection)) {
            ConfigCollection()
        } withDependencies: {
            $0.configClients.client = { _ in fake }
            $0.configClients.revisions = { _ in revisions }
        }
        store.exhaustivity = .off
        await store.send(.task)
        await store.receive(\.loaded)
        if let open { await store.send(.rowTapped(open)) }
        return Harness(store: store, fake: fake, revisions: revisions)
    }

    private static func submit(_ name: String, in harness: Harness) async {
        await harness.store.send(.nameEntry(.presented(.textChanged(name))))
        await harness.store.send(.nameEntry(.presented(.submitTapped)))
    }

    // MARK: loading

    @Test func loadingListsTheItemsAndSelectsNone() async throws {
        let harness = try await Self.harness()

        #expect(harness.core.items.map(\.name) == ["coder", "reviewer"])
        #expect(harness.core.selection == nil)
        #expect(harness.core.phase == .loaded)
        #expect(harness.core.actions == [.add, .rename, .duplicate, .delete])
    }

    @Test func aDaemonWithoutTheConfigAPIFailsTheLoad() async throws {
        let fake = try ConfigGolden.client(supported: false)
        let connection = DaemonConnection(daemon: .dionysus, secrets: DaemonSecrets(token: "t"))
        let store = TestStore(initialState: ConfigCollection.State(resource: "templates", daemon: .dionysus, connection: connection)) {
            ConfigCollection()
        } withDependencies: {
            $0.configClients.client = { _ in fake }
        }
        store.exhaustivity = .off

        await store.send(.task)
        await store.receive(\.loaded)

        guard case .failed = store.state.core.phase else {
            Issue.record("Expected failed")
            return
        }
    }

    @Test func tappingARowOpensItsDraft() async throws {
        let harness = try await Self.harness(open: "coder")

        #expect(harness.core.selection == "coder")
        #expect(harness.core.draft?.document.name == "coder")
        #expect(!harness.core.sections.isEmpty)
        #expect(!harness.core.isDirty)
    }

    // MARK: editing and saving

    @Test func anEditMarksTheDraftDirtyAndRevertClearsIt() async throws {
        let harness = try await Self.harness(open: "coder")

        await harness.store.send(.field("model", .string("sonnet")))
        #expect(harness.core.isDirty)

        await harness.store.send(.revertAllTapped)
        #expect(!harness.core.isDirty)
    }

    @Test func saveSendsOnlyTheChangedKeysWithTheRevision() async throws {
        let harness = try await Self.harness(open: "coder")
        let revision = try #require(harness.core.draft?.revision)
        await harness.store.send(.field("model", .string("sonnet")))

        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)

        let sent = await harness.updates()
        #expect(sent == [.update(resource: "templates", name: "coder", patch: ["model": .string("sonnet")], ifMatch: revision)])
        #expect(!harness.core.isDirty)
        #expect(harness.core.draft?.value(at: "model") == .string("sonnet"))
    }

    @Test func saveSendsNothingWhileUnchangedOrInvalid() async throws {
        let harness = try await Self.harness(open: "coder")

        await harness.store.send(.saveTapped)
        await harness.store.send(.field("max_turns", .string("lots")))
        await harness.store.send(.saveTapped)

        #expect(!harness.core.canSave)
        #expect(await harness.writes().isEmpty)
    }

    @Test func aRejectedValueLandsOnItsFieldAndKeepsTheEdit() async throws {
        let harness = try await Self.harness(open: "coder")
        await harness.fake.failNextWrite(with: LeoConfigError.invalid([LeoConfigFieldError(field: "model", message: "no such model")]))
        await harness.store.send(.field("model", .string("bogus")))

        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)

        #expect(harness.core.draft?.errors(for: "model") == ["no such model"])
        #expect(harness.core.isDirty)
        #expect(harness.core.selection == "coder")
    }

    @Test func aFailureWithNoFieldIsShownAndKeepsTheEdit() async throws {
        let harness = try await Self.harness(open: "coder")
        await harness.fake.failNextWrite(with: LeoDaemonError.daemon(code: "internal", message: "disk full", matches: []))
        await harness.store.send(.field("model", .string("sonnet")))

        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)

        #expect(harness.core.errorMessage == "disk full")
        #expect(harness.core.isDirty)
    }

    @Test func aSaveThatNeedsAnAgentRestartShowsTheBannerUntilDismissed() async throws {
        let harness = try await Self.harness(open: "coder")
        await harness.store.send(.field("model", .string("sonnet")))

        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)
        #expect(harness.core.restartPrompt == LeoConfigRestartRequired(service: false, agents: true))

        await harness.store.send(.dismissRestartBanner)
        #expect(harness.core.restartPrompt == nil)
    }

    @Test func theRestartBannerHandsTheRestartToTheMachine() async throws {
        let harness = try await Self.harness(open: "coder")
        await harness.store.send(.field("model", .string("sonnet")))
        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)

        await harness.store.send(.restartBannerTapped(.agents))

        await harness.store.receive(\.delegate.restart, .agents)
        #expect(harness.core.restartPrompt == nil)
    }

    // MARK: conflicts

    /// Another writer changes `coder` after this pane read it.
    private static func conflicted(_ harness: Harness, theirs: [String: LeoConfigValue] = ["workspace": .string("/tmp/theirs")]) async {
        await harness.fake.externalChange("templates", name: "coder", values: theirs)
    }

    @Test func aStaleRevisionRaisesTheConflictBannerAndKeepsTheEdit() async throws {
        let harness = try await Self.harness(open: "coder")
        await Self.conflicted(harness)
        await harness.store.send(.field("model", .string("sonnet")))

        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)

        #expect(harness.core.conflict != nil)
        #expect(harness.core.isDirty)
        #expect(harness.core.draft?.value(at: "model") == .string("sonnet"))
    }

    @Test func reloadRebasesTheEditsOntoTheNewDocument() async throws {
        let harness = try await Self.harness(open: "coder")
        await Self.conflicted(harness)
        await harness.store.send(.field("model", .string("sonnet")))
        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)

        await harness.store.send(.reloadTapped)
        await harness.store.receive(\.refreshed)

        #expect(harness.core.conflict == nil)
        #expect(harness.core.draft?.revision == (await harness.fake.currentRevision))
        #expect(harness.core.draft?.value(at: "workspace") == .string("/tmp/theirs"))
        #expect(harness.core.draft?.patch == ["model": .string("sonnet")])
    }

    @Test func overwriteReplaysTheEditsOverAFreshRead() async throws {
        let harness = try await Self.harness(open: "coder")
        await Self.conflicted(harness)
        await harness.store.send(.field("model", .string("sonnet")))
        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)
        let current = await harness.fake.currentRevision

        await harness.store.send(.overwriteTapped)
        await harness.store.receive(\.overwriteFinished)

        let sent = await harness.updates().last
        #expect(sent == .update(resource: "templates", name: "coder", patch: ["model": .string("sonnet")], ifMatch: current))
        #expect(harness.core.conflict == nil)
        #expect(!harness.core.isDirty)
        #expect(harness.core.draft?.value(at: "workspace") == .string("/tmp/theirs"))
    }

    private static func strings(_ names: String...) -> LeoConfigValue {
        .list(names.map(LeoConfigValue.string))
    }

    @Test func overwriteKeepsASetListEntryTheOtherWriterAddedWhileTheUserRemovedAnother() async throws {
        let harness = try await Self.harness(open: "coder", seed: ["channels": Self.strings("a", "b")])
        await harness.store.send(.field("channels", Self.strings("a")))
        await Self.conflicted(harness, theirs: ["channels": Self.strings("a", "b", "c")])
        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)
        #expect(harness.core.conflict != nil)

        await harness.store.send(.overwriteTapped)
        await harness.store.receive(\.overwriteFinished)

        let stored = try await harness.fake.item("templates", name: "coder").values["channels"]
        #expect(stored == Self.strings("a", "c"))
        #expect(harness.core.conflict == nil)
    }

    @Test func overwriteSendsAnOrderedListExactlyAsTyped() async throws {
        let harness = try await Self.harness(open: "coder", seed: ["add_dirs": Self.strings("a", "b")])
        await harness.store.send(.field("add_dirs", Self.strings("b", "a")))
        await Self.conflicted(harness, theirs: ["add_dirs": Self.strings("a", "b", "c")])
        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)

        await harness.store.send(.overwriteTapped)
        await harness.store.receive(\.overwriteFinished)

        let stored = try await harness.fake.item("templates", name: "coder").values["add_dirs"]
        #expect(stored == Self.strings("b", "a"))
    }

    @Test func overwriteSendsNothingWhenTheOtherWriterAlreadyMadeTheSameEdit() async throws {
        let harness = try await Self.harness(open: "coder")
        await Self.conflicted(harness, theirs: ["model": .string("sonnet")])
        await harness.store.send(.field("model", .string("sonnet")))
        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)
        let before = await harness.updates().count

        await harness.store.send(.overwriteTapped)
        await harness.store.receive(\.overwriteFinished)

        #expect(await harness.updates().count == before)
        #expect(harness.core.conflict == nil)
        #expect(!harness.core.isDirty)
    }

    // MARK: leaving the editor

    @Test func backWhileCleanClosesTheEditor() async throws {
        let harness = try await Self.harness(open: "coder")

        await harness.store.send(.backTapped)

        #expect(harness.core.selection == nil)
        #expect(harness.store.state.leaveDialog == nil)
    }

    @Test func backWhileDirtyAsksWhatToDoWithTheEdits() async throws {
        let harness = try await Self.harness(open: "coder")
        await harness.store.send(.field("model", .string("sonnet")))

        await harness.store.send(.backTapped)

        #expect(harness.store.state.leaveDialog != nil)
        #expect(harness.core.selection == "coder")
        #expect(harness.core.isDirty)
    }

    @Test func leavingWithSaveLeavesOnceTheWriteLanded() async throws {
        let harness = try await Self.harness(open: "coder")
        await harness.store.send(.field("model", .string("sonnet")))
        await harness.store.send(.backTapped)

        await harness.store.send(.leaveDialog(.presented(.save)))
        await harness.store.receive(\.writeFinished)

        #expect(await harness.updates().count == 1)
        #expect(harness.core.selection == nil)
    }

    @Test func leavingWithSaveStaysWhenTheWriteConflicts() async throws {
        let harness = try await Self.harness(open: "coder")
        await Self.conflicted(harness)
        await harness.store.send(.field("model", .string("sonnet")))
        await harness.store.send(.backTapped)

        await harness.store.send(.leaveDialog(.presented(.save)))
        await harness.store.receive(\.writeFinished)

        #expect(harness.core.selection == "coder")
        #expect(harness.core.conflict != nil)
        #expect(harness.core.isDirty)
        #expect(harness.store.state.leaveDialog == nil)
    }

    @Test func leavingWithSaveStaysWhenTheDaemonRejectsAValue() async throws {
        let harness = try await Self.harness(open: "coder")
        await harness.fake.failNextWrite(with: LeoConfigError.invalid([LeoConfigFieldError(field: "model", message: "no such model")]))
        await harness.store.send(.field("model", .string("bogus")))
        await harness.store.send(.backTapped)

        await harness.store.send(.leaveDialog(.presented(.save)))
        await harness.store.receive(\.writeFinished)

        #expect(harness.core.selection == "coder")
        #expect(harness.core.draft?.errors(for: "model") == ["no such model"])
    }

    @Test func leavingWithDiscardDropsTheEditsWithoutWriting() async throws {
        let harness = try await Self.harness(open: "coder")
        await harness.store.send(.field("model", .string("sonnet")))
        await harness.store.send(.backTapped)

        await harness.store.send(.leaveDialog(.presented(.discard)))

        #expect(harness.core.selection == nil)
        #expect(await harness.writes().isEmpty)
        await harness.store.send(.rowTapped("coder"))
        #expect(!harness.core.isDirty)
    }

    @Test func cancellingTheLeaveDialogKeepsTheEdits() async throws {
        let harness = try await Self.harness(open: "coder")
        await harness.store.send(.field("model", .string("sonnet")))
        await harness.store.send(.backTapped)

        await harness.store.send(.leaveDialog(.dismiss))

        #expect(harness.core.selection == "coder")
        #expect(harness.core.isDirty)
    }

    // MARK: a write that answers after the user moved on

    /// Waits until the fake daemon is sitting on a write.
    private static func untilHeld(_ fake: LeoFakeConfigClient) async {
        for _ in 0..<1_000 where await fake.heldWriteCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// Save on `coder` goes out and is held; the user discards, opens `reviewer`, and `reviewer` has one edit of its own.
    private static func movedOn(after start: (Harness) async -> Void) async throws -> Harness {
        let harness = try await Self.harness(open: "coder")
        await harness.fake.holdWrites()
        await start(harness)
        await Self.untilHeld(harness.fake)
        await harness.store.send(.backTapped)
        await harness.store.send(.leaveDialog(.presented(.discard)))
        await harness.store.send(.rowTapped("reviewer"))
        await harness.store.send(.field("workspace", .string("/tmp/reviewer")))
        return harness
    }

    @Test func aSaveRejectedAfterTheUserOpenedAnotherItemLeavesThatItemAlone() async throws {
        let harness = try await Self.movedOn { harness in
            await harness.store.send(.field("model", .string("bogus")))
            await harness.store.send(.saveTapped)
        }
        await harness.fake.failNextWrite(with: LeoConfigError.invalid([LeoConfigFieldError(field: "model", message: "no such model")]))

        await harness.fake.releaseWrites()
        await harness.store.receive(\.writeFinished)

        #expect(harness.core.selection == "reviewer")
        #expect(harness.core.draft?.document.name == "reviewer")
        #expect(harness.core.draft?.value(at: "model") != .string("bogus"))
        #expect(harness.core.draft?.errors(for: "model") == [])
        #expect(harness.core.draft?.patch == ["workspace": .string("/tmp/reviewer")])
        #expect(!harness.core.isBusy)
    }

    @Test func aSaveThatLandsAfterTheUserOpenedAnotherItemKeepsTheOpenItemAndItsEdits() async throws {
        let harness = try await Self.movedOn { harness in
            await harness.store.send(.field("model", .string("sonnet")))
            await harness.store.send(.saveTapped)
        }

        await harness.fake.releaseWrites()
        await harness.store.receive(\.writeFinished)

        #expect(harness.core.selection == "reviewer")
        #expect(harness.core.draft?.document.name == "reviewer")
        #expect(harness.core.draft?.patch == ["workspace": .string("/tmp/reviewer")])
        let stored = try await harness.fake.item("templates", name: "coder").values["model"]
        #expect(stored == .string("sonnet"))
    }

    @Test func saveSendsOnlyTheOpenItemsEditsAfterALateFailure() async throws {
        let harness = try await Self.movedOn { harness in
            await harness.store.send(.field("model", .string("bogus")))
            await harness.store.send(.saveTapped)
        }
        await harness.fake.failNextWrite(with: LeoConfigError.invalid([LeoConfigFieldError(field: "model", message: "no such model")]))
        await harness.fake.releaseWrites()
        await harness.store.receive(\.writeFinished)

        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)

        let last = await harness.updates().last
        guard case .update(_, let name, let patch, _)? = last else {
            Issue.record("Expected an update, got \(String(describing: last))")
            return
        }
        #expect(name == "reviewer")
        #expect(patch == ["workspace": .string("/tmp/reviewer")])
    }

    @Test func anOverwriteRejectedAfterTheUserOpenedAnotherItemLeavesThatItemAlone() async throws {
        let harness = try await Self.harness(open: "coder")
        await Self.conflicted(harness)
        await harness.store.send(.field("model", .string("bogus")))
        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)
        await harness.fake.holdWrites()
        await harness.store.send(.overwriteTapped)
        await Self.untilHeld(harness.fake)
        await harness.store.send(.backTapped)
        await harness.store.send(.leaveDialog(.presented(.discard)))
        await harness.store.send(.rowTapped("reviewer"))
        await harness.fake.failNextWrite(with: LeoConfigError.invalid([LeoConfigFieldError(field: "model", message: "no such model")]))

        await harness.fake.releaseWrites()
        await harness.store.receive(\.overwriteFinished)

        #expect(harness.core.selection == "reviewer")
        #expect(harness.core.draft?.document.name == "reviewer")
        #expect(harness.core.draft?.errors(for: "model") == [])
        #expect(!harness.core.isDirty)
        #expect(!harness.core.isBusy)
    }

    @Test func anOverwriteThatLandsAfterTheUserOpenedAnotherItemKeepsTheOpenItem() async throws {
        let harness = try await Self.harness(open: "coder")
        await Self.conflicted(harness)
        await harness.store.send(.field("model", .string("sonnet")))
        await harness.store.send(.saveTapped)
        await harness.store.receive(\.writeFinished)
        await harness.fake.holdWrites()
        await harness.store.send(.overwriteTapped)
        await Self.untilHeld(harness.fake)
        await harness.store.send(.backTapped)
        await harness.store.send(.leaveDialog(.presented(.discard)))
        await harness.store.send(.rowTapped("reviewer"))

        await harness.fake.releaseWrites()
        await harness.store.receive(\.overwriteFinished)

        #expect(harness.core.selection == "reviewer")
        #expect(harness.core.draft?.document.name == "reviewer")
        #expect(!harness.core.isBusy)
    }

    @Test func aSaveFromTheLeaveQuestionDoesNotCloseAnotherItemsEditor() async throws {
        let harness = try await Self.harness(open: "coder")
        await harness.fake.holdWrites()
        await harness.store.send(.field("model", .string("sonnet")))
        await harness.store.send(.backTapped)
        await harness.store.send(.leaveDialog(.presented(.save)))
        await Self.untilHeld(harness.fake)
        await harness.store.send(.rowTapped("reviewer"))
        #expect(harness.core.selection == "coder")

        await harness.fake.releaseWrites()
        await harness.store.receive(\.writeFinished)

        #expect(harness.core.selection == nil)
    }

    // MARK: the editor leaving the screen on its own

    @Test func theEditorPoppingWhileCleanClosesIt() async throws {
        let harness = try await Self.harness(open: "coder")

        await harness.store.send(.editorPopped)

        #expect(harness.core.selection == nil)
    }

    @Test func theEditorPoppingWhileDirtyKeepsTheDraftAndAsksNothingOffScreen() async throws {
        let harness = try await Self.harness(open: "coder")
        await harness.store.send(.field("model", .string("sonnet")))

        await harness.store.send(.editorPopped)

        #expect(harness.core.selection == "coder")
        #expect(harness.core.draft?.patch == ["model": .string("sonnet")])
        #expect(harness.store.state.leaveDialog == nil)
    }

    // MARK: add, rename, duplicate, delete

    @Test func deleteAsksWithTheItemsName() async throws {
        let harness = try await Self.harness()

        await harness.store.send(.deleteTapped("reviewer"))

        let alert = try #require(harness.store.state.alert)
        #expect(String(state: alert.title).contains("reviewer"))
        #expect(await harness.writes().isEmpty)
    }

    @Test func confirmingActsOnTheNameTheAlertShowedNotTheCurrentSelection() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.deleteTapped("reviewer"))
        await harness.store.send(.rowTapped("coder"))

        await harness.store.send(.alert(.presented(.confirmDelete("reviewer"))))
        await harness.store.receive(\.writeFinished)

        let calls = await harness.writes()
        guard case .delete(_, let name, _)? = calls.first else {
            Issue.record("Expected a delete, got \(calls)")
            return
        }
        #expect(name == "reviewer")
        #expect(harness.core.items.map(\.name) == ["coder"])
    }

    @Test func deleteIsRefusedWhileEditsAreUnsaved() async throws {
        let harness = try await Self.harness(open: "coder")
        await harness.store.send(.field("model", .string("sonnet")))

        await harness.store.send(.deleteTapped("reviewer"))

        #expect(harness.store.state.alert == nil)
    }

    @Test func renameKeepsTheListAndClosesTheSheet() async throws {
        let harness = try await Self.harness()

        await harness.store.send(.renameTapped("reviewer"))
        await Self.submit("critic", in: harness)
        await harness.store.receive(\.writeFinished)

        #expect(harness.core.items.map(\.name).sorted() == ["coder", "critic"])
        #expect(harness.core.selection == nil)
        #expect(harness.store.state.nameEntry == nil)
    }

    @Test func aNameIsCheckedBeforeAnythingIsSent() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.renameTapped("reviewer"))

        await Self.submit("coder", in: harness)

        #expect(harness.store.state.nameEntry?.error != nil)
        #expect(await harness.writes().isEmpty)
    }

    @Test func aNameTheDaemonRejectsShowsItsMessageInTheSheet() async throws {
        let harness = try await Self.harness()
        await harness.fake.failNextWrite(with: LeoDaemonError.daemon(code: "invalid_name", message: "reserved name", matches: []))
        await harness.store.send(.renameTapped("reviewer"))

        await Self.submit("critic", in: harness)
        await harness.store.receive(\.writeFinished)

        #expect(harness.store.state.nameEntry?.error == "reserved name")
        #expect(harness.core.items.map(\.name) == ["coder", "reviewer"])
    }

    @Test func duplicateOpensTheCopy() async throws {
        let harness = try await Self.harness()

        await harness.store.send(.duplicateTapped("coder"))
        await Self.submit("coder2", in: harness)
        await harness.store.receive(\.writeFinished)

        #expect(harness.core.selection == "coder2")
        #expect(harness.store.state.nameEntry == nil)
    }

    @Test func addOpensTheNewItem() async throws {
        let harness = try await Self.harness()

        await harness.store.send(.addTapped)
        await Self.submit("fresh", in: harness)
        await harness.store.receive(\.writeFinished)

        #expect(harness.core.selection == "fresh")
    }

    @Test func duplicateIsOfferedOnlyWhereTheSchemaListsIt() async throws {
        let harness = try await Self.harness(resource: "environments")

        await harness.store.send(.duplicateTapped("base"))

        #expect(harness.store.state.nameEntry == nil)
        #expect(!harness.core.allows(.duplicate))
        #expect(harness.core.allows(.rename))
    }

    @Test func cancellingTheSheetSendsNothing() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.addTapped)

        await harness.store.send(.nameEntry(.presented(.cancelTapped)))

        #expect(harness.store.state.nameEntry == nil)
        #expect(await harness.writes().isEmpty)
    }

    // MARK: the machine

    @Test func aDisconnectKeepsTheEditorAndItsDraft() async throws {
        let harness = try await Self.harness(open: "coder")
        await harness.store.send(.field("model", .string("sonnet")))

        await harness.store.send(.machine(.connectionChanged(false)))

        #expect(!harness.store.state.isMachineConnected)
        #expect(harness.core.selection == "coder")
        #expect(harness.core.isDirty)
        #expect(await harness.writes().isEmpty)
    }

    @Test func aReconnectReadsAgainAndKeepsTheEditsOverTheNewDocument() async throws {
        let harness = try await Self.harness(open: "coder")
        await harness.store.send(.field("model", .string("sonnet")))
        await harness.store.send(.machine(.connectionChanged(false)))
        await Self.conflicted(harness)

        await harness.store.send(.machine(.connectionChanged(true)))
        await harness.store.receive(\.refreshed)

        #expect(harness.store.state.isMachineConnected)
        #expect(harness.core.draft?.value(at: "workspace") == .string("/tmp/theirs"))
        #expect(harness.core.draft?.patch == ["model": .string("sonnet")])
    }

    @Test func aReconnectAfterAFailedLoadLoadsAgain() async throws {
        let fake = try ConfigGolden.client()
        let connection = DaemonConnection(daemon: .dionysus, secrets: DaemonSecrets(token: "t"))
        let store = TestStore(initialState: ConfigCollection.State(resource: "templates", daemon: .dionysus, connection: connection)) {
            ConfigCollection()
        } withDependencies: {
            $0.configClients.client = { _ in fake }
        }
        store.exhaustivity = .off
        await fake.failNextRead(with: LeoDaemonError.daemon(code: "internal", message: "down", matches: []))
        await store.send(.task)
        await store.receive(\.loaded)

        await store.send(.machine(.connectionChanged(true)))
        await store.receive(\.loaded)

        #expect(store.state.core.phase == .loaded)
        #expect(store.state.core.items.count == 2)
    }

    // MARK: the web link

    @Test func theWebLinkGoesThroughTheOriginTheMachineWasPairedOn() async throws {
        let harness = try await Self.harness(open: "coder")

        #expect(harness.core.webLink?.absoluteString == "https://leo.example.com/config/templates/coder")
    }

    @Test func aPairedOriginThatIsNotWebHasNoLink() async throws {
        let relay = PairedDaemon(
            id: "d-relay", name: "relay", baseURL: URL(string: "wss://relay.example.com")!,
            urls: [], deviceID: "dev-3", pairedAt: Date(timeIntervalSince1970: 3_000)
        )
        let harness = try await Self.harness(open: "coder", daemon: relay)

        #expect(harness.core.webLink == nil)
    }
}
