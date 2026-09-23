import AppKit
import Foundation
import Testing

@testable import Ghostty

/// Every close of a tab, a window or the app goes through the gate, so
/// unsaved editor edits are never dropped: a close that can ask asks about
/// each editor with unsaved edits in turn (Save / Don't Save / Cancel) and
/// goes ahead once all are resolved; Cancel drops it. And the user can
/// always leave: an editor stuck on a save or read that never comes back
/// can be left anyway.
@MainActor
struct LeoUnsavedEditorsGateTests {
    /// Answers every prompt with `answer`, recording who was asked, which
    /// windows were brought forward, and how each close came out.
    private final class Log {
        var asked: [String] = []
        var broughtForward: [String] = []
        var outcomes: [String: Bool] = [:]
        var offers: [LeoUnsavedEditorsGate.Leaving] = []
    }

    private func pane(answering answer: LeoUnsavedChangesChoice, log: Log, access: (any LeoFileAccess)? = nil) -> LeoEditorPaneModel {
        let pane = LeoEditorPaneModel(makeAccess: { _ in access ?? LeoFileAccessor.local() })
        pane.confirmUnsaved = { document in
            log.asked.append(document.displayName)
            return answer
        }
        return pane
    }

    private func open(_ pane: LeoEditorPaneModel, _ path: String, editing: Bool) async throws {
        try await pane.open(LeoEditorFileID(host: .local, path: path))
        if editing, let document = pane.document { document.edit(document.text + "!") }
    }

    private func entry(_ pane: LeoEditorPaneModel, _ name: String, _ log: Log) -> LeoUnsavedEditorsGate.Entry {
        LeoUnsavedEditorsGate.Entry(editor: pane) { log.broughtForward.append(name) }
    }

    /// A gate whose "leave anyway?" alert answers `leave`.
    private func gate(leaving leave: Bool = false, log: Log) -> LeoUnsavedEditorsGate {
        LeoUnsavedEditorsGate { _, leaving in
            log.offers.append(leaving)
            return leave
        }
    }

    /// Polls: outcomes arrive from tasks the gate starts. `false` if
    /// `condition` never held.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func withoutUnsavedEditsTheCloseGoesAheadUnasked() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let clean = pane(answering: .cancel, log: log)
            try await open(clean, try sandbox.file("a.txt", "a"), editing: false)
            let empty = pane(answering: .cancel, log: log)
            let gate = gate(log: log)

            let tookOver = gate.deferClose(of: [entry(clean, "1", log), entry(empty, "2", log)]) { log.outcomes["close"] = $0 }

            #expect(!tookOver)
            #expect(log.asked.isEmpty)
            #expect(log.outcomes.isEmpty)
            await clean.close()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func unsavedEditsAreAskedAboutFirstThenTheCloseGoesAhead() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let dirty = pane(answering: .discard, log: log)
            try await open(dirty, try sandbox.file("a.txt", "a"), editing: true)
            let gate = gate(log: log)

            try #require(gate.deferClose(of: [entry(dirty, "1", log)]) { log.outcomes["close"] = $0 })
            #expect(log.outcomes.isEmpty)
            #expect(await eventually { log.outcomes["close"] != nil })

            #expect(log.asked == ["a.txt"])
            #expect(log.broughtForward == ["1"])
            #expect(log.outcomes == ["close": true])
            #expect(dirty.document == nil)
            #expect(try sandbox.contents("a.txt") == "a")
            #expect(!gate.isAsking)
        }
    }

    @Test func eachEditorIsAskedInTurnAndCancelStopsTheClose() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let saved = pane(answering: .save, log: log)
            try await open(saved, try sandbox.file("a.txt", "a"), editing: true)
            let clean = pane(answering: .cancel, log: log)
            try await open(clean, try sandbox.file("b.txt", "b"), editing: false)
            let cancelled = pane(answering: .cancel, log: log)
            try await open(cancelled, try sandbox.file("c.txt", "c"), editing: true)
            let untouched = pane(answering: .discard, log: log)
            try await open(untouched, try sandbox.file("d.txt", "d"), editing: true)
            let gate = gate(log: log)

            let resolved = await gate.resolve([saved, clean, cancelled, untouched].enumerated().map { entry($1, "\($0)", log) })

            #expect(!resolved)
            #expect(log.asked == ["a.txt", "c.txt"])
            #expect(log.broughtForward == ["0", "2"])
            #expect(try sandbox.contents("a.txt") == "a!")
            #expect(saved.document == nil)
            #expect(cancelled.document?.isDirty == true)
            #expect(untouched.document?.isDirty == true)
            for pane in [clean, cancelled, untouched] {
                pane.confirmUnsaved = { _ in .discard }
                await pane.close()
            }
        }
    }

    /// Save fails while the file changed on disk (a banner is up): the
    /// edits stay, and so does everything else.
    @Test func aSaveThatCantGoThroughStopsTheClose() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let dirty = pane(answering: .save, log: log)
            try await open(dirty, try sandbox.file("a.txt", "a"), editing: true)
            try sandbox.file("a.txt", "a, changed elsewhere")
            #expect(await dirty.document?.checkDisk() == .conflict)
            let gate = gate(log: log)

            #expect(await !gate.resolve([entry(dirty, "1", log)]))

            #expect(dirty.document?.isDirty == true)
            #expect(try sandbox.contents("a.txt") == "a, changed elsewhere")
            dirty.confirmUnsaved = { _ in .discard }
            await dirty.close()
        }
    }

    /// One prompt per editor at a time: a close asked for while the user
    /// is answering one (⌘W twice, ⌘Q during Close Tab) is dropped -- its
    /// outcome is `false`, later -- not queued.
    @Test(.timeLimit(.minutes(1)))
    func aCloseRequestedWhileAskingIsDropped() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let (answers, answer) = AsyncStream<LeoUnsavedChangesChoice>.makeStream()
            let (prompts, prompted) = AsyncStream<Void>.makeStream()
            let dirty = LeoEditorPaneModel(makeAccess: { _ in LeoFileAccessor.local() })
            dirty.confirmUnsaved = { document in
                log.asked.append(document.displayName)
                prompted.yield()
                for await choice in answers { return choice }
                return .cancel
            }
            try await open(dirty, try sandbox.file("a.txt", "a"), editing: true)
            let gate = gate(leaving: true, log: log)

            try #require(gate.deferClose(of: [entry(dirty, "1", log)]) { log.outcomes["first"] = $0 })
            for await _ in prompts { break }
            #expect(gate.isAsking)
            #expect(gate.deferClose(of: [entry(dirty, "1", log)]) { log.outcomes["second"] = $0 })
            #expect(log.outcomes["second"] == nil)
            #expect(await eventually { log.outcomes["second"] != nil })
            answer.yield(.discard)
            #expect(await eventually { log.outcomes["first"] != nil })

            #expect(log.asked == ["a.txt"])
            #expect(log.outcomes == ["first": true, "second": false])
            #expect(log.offers.isEmpty)
            #expect(!gate.isAsking)
        }
    }

    /// ...but closing a window with nothing unsaved goes ahead meanwhile.
    @Test(.timeLimit(.minutes(1)))
    func aCloseWithNothingUnsavedGoesAheadWhileAsking() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let (answers, answer) = AsyncStream<LeoUnsavedChangesChoice>.makeStream()
            let (prompts, prompted) = AsyncStream<Void>.makeStream()
            let dirty = LeoEditorPaneModel(makeAccess: { _ in LeoFileAccessor.local() })
            dirty.confirmUnsaved = { _ in
                prompted.yield()
                for await choice in answers { return choice }
                return .cancel
            }
            try await open(dirty, try sandbox.file("a.txt", "a"), editing: true)
            let clean = pane(answering: .cancel, log: log)
            let gate = gate(log: log)
            try #require(gate.deferClose(of: [entry(dirty, "1", log)]) { log.outcomes["first"] = $0 })
            for await _ in prompts { break }

            #expect(!gate.deferClose(of: [entry(clean, "2", log)]) { log.outcomes["clean"] = $0 })

            answer.yield(.discard)
            #expect(await eventually { log.outcomes["first"] != nil })
            #expect(log.outcomes == ["first": true])
        }
    }

    // MARK: Leaving anyway

    /// The remote stops answering mid-save: the prompt is gone, the save
    /// never returns. Asking again (⌘Q) offers to leave anyway, which
    /// drops that editor's edits and lets the quit go ahead.
    @Test(.timeLimit(.minutes(1)))
    func aSaveThatNeverReturnsCanBeLeftAnyway() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let stuck = pane(answering: .save, log: log, access: access)
            try await open(stuck, try sandbox.file("a.txt", "a"), editing: true)
            access.hangsWrites = true
            let gate = gate(leaving: true, log: log)
            try #require(gate.deferClose(of: [entry(stuck, "1", log)], leaving: .quit) { log.outcomes["first"] = $0 })
            await access.waitUntilWriting()

            try #require(gate.deferClose(of: [entry(stuck, "1", log)], leaving: .quit) { log.outcomes["second"] = $0 })
            #expect(await eventually { log.outcomes["second"] != nil })

            #expect(log.offers == [.quit])
            #expect(log.outcomes == ["first": false, "second": true])
            #expect(stuck.document == nil)
            #expect(!gate.isAsking)
            #expect(await eventually { access.isClosed })
            #expect(try sandbox.contents("a.txt") == "a")
        }
    }

    /// Keep Waiting: nothing is dropped, and the first close goes ahead
    /// once the save comes back.
    @Test(.timeLimit(.minutes(1)))
    func keepWaitingLeavesTheStuckSaveToFinish() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let stuck = pane(answering: .save, log: log, access: access)
            try await open(stuck, try sandbox.file("a.txt", "a"), editing: true)
            access.hangsWrites = true
            let gate = gate(leaving: false, log: log)
            try #require(gate.deferClose(of: [entry(stuck, "1", log)], leaving: .quit) { log.outcomes["first"] = $0 })
            await access.waitUntilWriting()

            try #require(gate.deferClose(of: [entry(stuck, "1", log)], leaving: .quit) { log.outcomes["second"] = $0 })
            #expect(await eventually { log.outcomes["second"] != nil })
            #expect(log.outcomes == ["second": false])
            #expect(stuck.document?.isDirty == true)

            access.release()
            #expect(await eventually { log.outcomes["first"] != nil })
            #expect(log.outcomes == ["first": true, "second": false])
            #expect(try sandbox.contents("a.txt") == "a!")
        }
    }

    /// Leaving the stuck editor anyway only gives up its edits: another
    /// editor with unsaved edits is still asked about, and its answer
    /// decides -- on the paths that don't retry: a system quit's reply,
    /// and `resolve` (Ghostty's quit review).
    @Test(.timeLimit(.minutes(1)), arguments: [(LeoUnsavedChangesChoice.discard, true), (.cancel, false)])
    func leavingAStuckEditorStillAsksAboutTheOthers(_ answer: LeoUnsavedChangesChoice, goesOn: Bool) async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            for path in ["systemQuit", "resolve"] {
                let log = Log()
                let access = LeoHangingAccess(LeoFileAccessor.local())
                let stuck = pane(answering: .save, log: log, access: access)
                try await open(stuck, try sandbox.file("a-\(path).txt", "a"), editing: true)
                access.hangsWrites = true
                let other = pane(answering: answer, log: log)
                try await open(other, try sandbox.file("b-\(path).txt", "b"), editing: true)
                let gate = gate(leaving: true, log: log)
                try #require(gate.deferClose(of: [entry(stuck, "1", log)]) { log.outcomes["first"] = $0 })
                await access.waitUntilWriting()
                let both = [entry(stuck, "1", log), entry(other, "2", log)]

                let wentOn: Bool
                if path == "systemQuit" {
                    var replies: [Bool] = []
                    #expect(gate.deferQuit(of: both, isSystemQuit: true, reply: { replies.append($0) }, retry: {}) == .terminateLater)
                    #expect(await eventually { !replies.isEmpty })
                    try? await Task.sleep(for: .milliseconds(50))
                    #expect(replies.count == 1, "\(path)")
                    wentOn = replies.first ?? !goesOn
                } else {
                    wentOn = await gate.resolve(both)
                }

                #expect(wentOn == goesOn, "\(path)")
                #expect(log.offers == [.quit], "\(path): a quit says Quit Anyway, not Close Anyway")
                #expect(log.asked == ["a-\(path).txt", "b-\(path).txt"], "\(path)")
                #expect(stuck.document == nil, "\(path)")
                #expect((other.document?.isDirty == true) == !goesOn, "\(path)")
                if !goesOn {
                    other.confirmUnsaved = { _ in .discard }
                    await other.close()
                }
            }
        }
    }

    /// One stuck editor doesn't hold up closing another window.
    @Test(.timeLimit(.minutes(1)))
    func anotherEditorsCloseGoesAheadWhileOneIsStuck() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let stuck = pane(answering: .save, log: log, access: access)
            try await open(stuck, try sandbox.file("a.txt", "a"), editing: true)
            access.hangsWrites = true
            let other = pane(answering: .discard, log: log)
            try await open(other, try sandbox.file("b.txt", "b"), editing: true)
            let gate = gate(log: log)
            try #require(gate.deferClose(of: [entry(stuck, "1", log)]) { log.outcomes["stuck"] = $0 })
            await access.waitUntilWriting()

            try #require(gate.deferClose(of: [entry(other, "2", log)]) { log.outcomes["other"] = $0 })
            #expect(await eventually { log.outcomes["other"] != nil })

            #expect(log.asked == ["a.txt", "b.txt"])
            #expect(log.outcomes == ["other": true])
            #expect(log.offers.isEmpty)
            access.release()
            #expect(await eventually { log.outcomes["stuck"] != nil })
        }
    }

    // MARK: Quitting

    /// Logging out, restarting or shutting down waits for the answers --
    /// `.terminateLater` -- and then goes on: `reply` runs exactly once.
    @Test(.timeLimit(.minutes(1)), arguments: [(LeoUnsavedChangesChoice.discard, true), (.save, true), (.cancel, false)])
    func aSystemQuitWaitsForTheAnswersThenReplies(_ answer: LeoUnsavedChangesChoice, goesOn: Bool) async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let dirty = pane(answering: answer, log: log)
            try await open(dirty, try sandbox.file("a.txt", "a"), editing: true)
            let gate = gate(log: log)
            var replies: [Bool] = []
            var retries = 0

            let reply = gate.deferQuit(of: [entry(dirty, "1", log)], isSystemQuit: true, reply: { replies.append($0) }, retry: { retries += 1 })

            #expect(reply == .terminateLater)
            #expect(replies.isEmpty)
            #expect(await eventually { !replies.isEmpty })
            try? await Task.sleep(for: .milliseconds(50))
            #expect(replies == [goesOn])
            #expect(retries == 0)
            if answer == .cancel {
                dirty.confirmUnsaved = { _ in .discard }
                await dirty.close()
            }
        }
    }

    /// A system quit while a prompt is up is answered no, once.
    @Test(.timeLimit(.minutes(1)))
    func aSystemQuitWhileAskingIsAnsweredNoOnce() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let (answers, answer) = AsyncStream<LeoUnsavedChangesChoice>.makeStream()
            let (prompts, prompted) = AsyncStream<Void>.makeStream()
            let dirty = LeoEditorPaneModel(makeAccess: { _ in LeoFileAccessor.local() })
            dirty.confirmUnsaved = { _ in
                prompted.yield()
                for await choice in answers { return choice }
                return .cancel
            }
            try await open(dirty, try sandbox.file("a.txt", "a"), editing: true)
            let gate = gate(log: log)
            try #require(gate.deferClose(of: [entry(dirty, "1", log)]) { log.outcomes["close"] = $0 })
            for await _ in prompts { break }
            var replies: [Bool] = []

            #expect(gate.deferQuit(of: [entry(dirty, "1", log)], isSystemQuit: true, reply: { replies.append($0) }, retry: {}) == .terminateLater)

            #expect(await eventually { !replies.isEmpty })
            #expect(replies == [false])
            answer.yield(.discard)
            #expect(await eventually { log.outcomes["close"] != nil })
            #expect(replies == [false])
        }
    }

    /// ⌘Q (or installing an update) is cancelled now and retried once the
    /// edits are resolved, so a second ⌘Q can still reach the gate.
    @Test(.timeLimit(.minutes(1)))
    func aQuitIsCancelledThenRetried() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let dirty = pane(answering: .discard, log: log)
            try await open(dirty, try sandbox.file("a.txt", "a"), editing: true)
            let clean = pane(answering: .cancel, log: log)
            let gate = gate(log: log)
            var replies: [Bool] = []
            var retries = 0

            #expect(gate.deferQuit(of: [entry(clean, "0", log)], isSystemQuit: false, reply: { replies.append($0) }, retry: { retries += 1 }) == nil)
            let reply = gate.deferQuit(of: [entry(dirty, "1", log)], isSystemQuit: false, reply: { replies.append($0) }, retry: { retries += 1 })

            #expect(reply == .terminateCancel)
            #expect(await eventually { retries > 0 })
            #expect(retries == 1)
            #expect(replies.isEmpty)
        }
    }

    // MARK: Edits made while a close is under way (B-022)

    /// A pane that holds its prompt until `answer` yields, signalling each
    /// prompt on `prompted`.
    private func heldPane(
        _ log: Log, access: (any LeoFileAccess)? = nil
    ) -> (LeoEditorPaneModel, AsyncStream<Void>, AsyncStream<LeoUnsavedChangesChoice>.Continuation) {
        let (answers, answer) = AsyncStream<LeoUnsavedChangesChoice>.makeStream()
        let (prompts, prompted) = AsyncStream<Void>.makeStream()
        let pane = LeoEditorPaneModel(makeAccess: { _ in access ?? LeoFileAccessor.local() })
        pane.confirmUnsaved = { document in
            log.asked.append(document.displayName)
            prompted.yield()
            for await choice in answers { return choice }
            return .cancel
        }
        return (pane, prompts, answer)
    }

    /// An editor edited while the close asks about another one is asked
    /// about too, in its turn.
    @Test(.timeLimit(.minutes(1)))
    func anEditorEditedDuringTheCloseIsAskedAboutToo() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let (first, prompts, answer) = heldPane(log)
            try await open(first, try sandbox.file("a.txt", "a"), editing: true)
            let later = pane(answering: .discard, log: log)
            try await open(later, try sandbox.file("b.txt", "b"), editing: false)
            let gate = gate(log: log)
            var replies: [Bool] = []
            #expect(gate.deferQuit(
                of: [entry(first, "1", log), entry(later, "2", log)], isSystemQuit: true, reply: { replies.append($0) }, retry: {}
            ) == .terminateLater)
            for await _ in prompts { break }

            later.document?.edit("b, edited while asked about a")
            answer.yield(.discard)
            #expect(await eventually { !replies.isEmpty })

            #expect(log.asked == ["a.txt", "b.txt"])
            #expect(replies == [true])
            #expect(later.document == nil)
        }
    }

    /// ...even one the close already passed over: clean when its turn came,
    /// edited while a later editor's prompt was up. Both the logout's reply
    /// and `resolve` (Ghostty's quit review) wait for its answer.
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func anEarlierEditorEditedDuringTheCloseIsAskedAboutToo(_ isSystemQuit: Bool) async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let earlier = pane(answering: .cancel, log: log)
            try await open(earlier, try sandbox.file("a.txt", "a"), editing: false)
            let (dirty, prompts, answer) = heldPane(log)
            try await open(dirty, try sandbox.file("b.txt", "b"), editing: true)
            let gate = gate(log: log)
            let both = [entry(earlier, "1", log), entry(dirty, "2", log)]
            var replies: [Bool] = []
            let pending = Task { @MainActor in
                if isSystemQuit {
                    #expect(gate.deferQuit(of: both, isSystemQuit: true, reply: { replies.append($0) }, retry: {}) == .terminateLater)
                } else {
                    replies.append(await gate.resolve(both))
                }
            }
            for await _ in prompts { break }

            earlier.document?.edit("a, edited while asked about b")
            answer.yield(.discard)
            #expect(await eventually { !replies.isEmpty })
            await pending.value

            #expect(log.asked == ["b.txt", "a.txt"])
            #expect(replies == [false], "Cancel on a.txt stops the quit")
            #expect(earlier.document?.isDirty == true)
            earlier.confirmUnsaved = { _ in .discard }
            await earlier.close()
        }
    }

    /// ...and so is one edited while the Keep Waiting / Quit Anyway offer
    /// is up: leaving the stuck editor asks about it rather than dropping it.
    @Test(.timeLimit(.minutes(1)))
    func anEditorEditedDuringTheOfferIsAskedAboutToo() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let stuck = pane(answering: .save, log: log, access: access)
            try await open(stuck, try sandbox.file("a.txt", "a"), editing: true)
            access.hangsWrites = true
            let later = pane(answering: .cancel, log: log)
            try await open(later, try sandbox.file("b.txt", "b"), editing: false)
            let (offers, offered) = AsyncStream<Void>.makeStream()
            let (leaves, leave) = AsyncStream<Bool>.makeStream()
            let gate = LeoUnsavedEditorsGate { _, _ in
                offered.yield()
                for await answer in leaves { return answer }
                return false
            }
            try #require(gate.deferClose(of: [entry(stuck, "1", log)]) { log.outcomes["first"] = $0 })
            await access.waitUntilWriting()
            var replies: [Bool] = []
            #expect(gate.deferQuit(
                of: [entry(stuck, "1", log), entry(later, "2", log)], isSystemQuit: true, reply: { replies.append($0) }, retry: {}
            ) == .terminateLater)
            for await _ in offers { break }

            later.document?.edit("b, edited during the offer")
            leave.yield(true)
            #expect(await eventually { !replies.isEmpty })

            #expect(log.asked == ["a.txt", "b.txt"])
            #expect(replies == [false], "Cancel on b.txt stops the quit")
            #expect(later.document?.isDirty == true)
            later.confirmUnsaved = { _ in .discard }
            await later.close()
        }
    }

    // MARK: Leaving from inside a pending quit (B-022, D-038)

    /// Logging out behind a save that never comes back: the pending quit
    /// itself offers to leave (the stuck editor's `leaveAnyway`), with no
    /// second ⌘Q. Leaving gives up that editor's edits; the others are
    /// still asked about, and the quit's reply comes once.
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func aPendingQuitOffersToLeaveAHungSave(_ isSystemQuit: Bool) async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let stuck = pane(answering: .save, log: log, access: access)
            try await open(stuck, try sandbox.file("a.txt", "a"), editing: true)
            access.hangsWrites = true
            let other = pane(answering: .discard, log: log)
            try await open(other, try sandbox.file("b.txt", "b"), editing: true)
            let gate = gate(leaving: true, log: log)
            let both = [entry(stuck, "1", log), entry(other, "2", log)]
            var replies: [Bool] = []
            let pending = Task { @MainActor in
                if isSystemQuit {
                    #expect(gate.deferQuit(of: both, isSystemQuit: true, reply: { replies.append($0) }, retry: {}) == .terminateLater)
                } else {
                    replies.append(await gate.resolve(both))
                }
            }
            await access.waitUntilWriting()

            #expect(await eventually { stuck.leaveAnyway != nil && !stuck.isConfirming })
            #expect(other.leaveAnyway == nil)
            stuck.leaveAnyway?()
            #expect(await eventually { !replies.isEmpty })
            await pending.value
            try? await Task.sleep(for: .milliseconds(50))

            #expect(log.offers == [.quit])
            #expect(replies == [true])
            #expect(log.asked == ["a.txt", "b.txt"])
            #expect(stuck.document == nil)
            #expect(other.document == nil)
            #expect(stuck.leaveAnyway == nil)
            #expect(!gate.isAsking)
            #expect(try sandbox.contents("a.txt") == "a")
        }
    }

    /// ⌘W on the stuck editor during a pending logout offers to close it
    /// anyway; leaving then goes the same way as the banner's: the logout
    /// goes on (asking about the others), rather than being cancelled.
    @Test(.timeLimit(.minutes(1)))
    func commandWOnTheStuckEditorLetsAPendingQuitGoOn() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let stuck = pane(answering: .save, log: log, access: access)
            try await open(stuck, try sandbox.file("a.txt", "a"), editing: true)
            access.hangsWrites = true
            let other = pane(answering: .discard, log: log)
            try await open(other, try sandbox.file("b.txt", "b"), editing: true)
            let gate = gate(leaving: true, log: log)
            var replies: [Bool] = []
            #expect(gate.deferQuit(
                of: [entry(stuck, "1", log), entry(other, "2", log)], isSystemQuit: true, reply: { replies.append($0) }, retry: {}
            ) == .terminateLater)
            await access.waitUntilWriting()

            try #require(gate.deferClose(of: [entry(stuck, "1", log)]) { log.outcomes["commandW"] = $0 })
            #expect(await eventually { !replies.isEmpty && log.outcomes["commandW"] != nil })
            try? await Task.sleep(for: .milliseconds(50))

            #expect(log.offers == [.close])
            #expect(log.outcomes == ["commandW": true])
            #expect(replies == [true], "the logout goes on")
            #expect(log.asked == ["a.txt", "b.txt"])
            #expect(stuck.document == nil)
            #expect(other.document == nil)
            #expect(!gate.isAsking)
        }
    }

    /// Keep Waiting changes nothing: the offer stays reachable, and the
    /// quit goes on once the save comes back.
    @Test(.timeLimit(.minutes(1)))
    func keepWaitingInsideAPendingQuitWaitsForTheSave() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let stuck = pane(answering: .save, log: log, access: access)
            try await open(stuck, try sandbox.file("a.txt", "a"), editing: true)
            access.hangsWrites = true
            let gate = gate(leaving: false, log: log)
            var replies: [Bool] = []
            #expect(gate.deferQuit(of: [entry(stuck, "1", log)], isSystemQuit: true, reply: { replies.append($0) }, retry: {}) == .terminateLater)
            await access.waitUntilWriting()
            #expect(await eventually { stuck.leaveAnyway != nil && !stuck.isConfirming })

            stuck.leaveAnyway?()
            #expect(await eventually { log.offers.count == 1 })
            try? await Task.sleep(for: .milliseconds(50))
            #expect(replies.isEmpty)
            #expect(stuck.leaveAnyway != nil)

            access.release()
            #expect(await eventually { !replies.isEmpty })
            #expect(replies == [true])
            #expect(stuck.leaveAnyway == nil)
            #expect(try sandbox.contents("a.txt") == "a!")
        }
    }

    /// A close that can be asked again (⌘W, ⌘Q) doesn't offer from inside:
    /// asking again is the way to leave.
    @Test(.timeLimit(.minutes(1)))
    func anOrdinaryCloseDoesNotOfferFromInside() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let log = Log()
            let access = LeoHangingAccess(LeoFileAccessor.local())
            let stuck = pane(answering: .save, log: log, access: access)
            try await open(stuck, try sandbox.file("a.txt", "a"), editing: true)
            access.hangsWrites = true
            let gate = gate(log: log)
            #expect(gate.deferQuit(of: [entry(stuck, "1", log)], isSystemQuit: false, reply: { _ in }, retry: {}) == .terminateCancel)
            await access.waitUntilWriting()

            #expect(stuck.leaveAnyway == nil)
            access.release()
            #expect(await eventually { stuck.document == nil })
        }
    }

    @Test func theQuitsReasonComesFromItsAppleEvent() {
        func quit(why: OSType?) -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication), targetDescriptor: nil,
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
            )
            if let why { event.setAttribute(NSAppleEventDescriptor(typeCode: why), forKeyword: "why?".fourCharCode) }
            return event
        }

        #expect(LeoQuitReason.isSystemQuit(quit(why: OSType(kAEReallyLogOut))))
        #expect(LeoQuitReason.isSystemQuit(quit(why: OSType(kAERestart))))
        #expect(LeoQuitReason.isSystemQuit(quit(why: OSType(kAEShutDown))))
        #expect(!LeoQuitReason.isSystemQuit(quit(why: nil)))
        #expect(!LeoQuitReason.isSystemQuit(nil))
    }
}

/// `base`, except that while `hangsWrites` (or `hangsReads`) is set,
/// `write` (or `read`) never returns until `release()` -- or `close()`,
/// which fails it, as a closed SFTP connection fails what's in flight.
final class LeoHangingAccess: LeoFileAccess, @unchecked Sendable {
    private let base: any LeoFileAccess
    private let lock = NSLock()
    private var state = (hangingWrites: false, hangingReads: false, closed: false)
    private let writing = AsyncStream<Void>.makeStream()
    private let reading = AsyncStream<Void>.makeStream()
    private let gate = AsyncStream<Bool>.makeStream()

    init(_ base: any LeoFileAccess) {
        self.base = base
    }

    var hangsWrites: Bool {
        get { lock.withLock { state.hangingWrites } }
        set { lock.withLock { state.hangingWrites = newValue } }
    }

    var hangsReads: Bool {
        get { lock.withLock { state.hangingReads } }
        set { lock.withLock { state.hangingReads = newValue } }
    }

    var isClosed: Bool { lock.withLock { state.closed } }

    func waitUntilWriting() async {
        for await _ in writing.stream { return }
    }

    func waitUntilReading() async {
        for await _ in reading.stream { return }
    }

    func release() {
        gate.continuation.yield(true)
    }

    func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }

    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents {
        if hangsReads {
            reading.continuation.yield()
            try await hang()
        }
        return try await base.read(path, maxBytes: maxBytes)
    }

    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        if hangsWrites {
            writing.continuation.yield()
            try await hang()
        }
        return try await base.write(data, to: path, expecting: expected)
    }

    private func hang() async throws {
        var released = false
        for await proceed in gate.stream {
            released = proceed
            break
        }
        guard released else { throw LeoFileAccessError.disconnected }
    }

    func close() async {
        lock.withLock { state.closed = true }
        gate.continuation.yield(false)
        await base.close()
    }
}
