import AppKit
import Foundation
import Testing

@testable import Ghostty

/// B-013 on the main actor: which surfaced files are pending (unseen), that
/// a snapshot, focus or row click never opens one (only a live event does,
/// in the background: B-273, `LeoSurfacedAutoOpenTests`), what the menus
/// open, and that seen ids persist per host, bounded.
@MainActor
struct LeoSurfacedFileRoutingTests {
    // MARK: Seen ledger

    @Test func seenIdsPersistPerHost() {
        let defaults = LeoInMemoryDefaults()
        let store = LeoUserDefaultsSurfacedFileSeenStore(defaults: defaults)
        let one = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let two = surfaced("u-2", agent: "alpha", startedAt: "s1")
        store.save(LeoSurfacedFileLedger().markingSeen(one, host: .local).markingSeen(two, host: .remote("work")))

        let reloaded = LeoUserDefaultsSurfacedFileSeenStore(defaults: defaults).load()
        #expect(reloaded.isSeen(one, host: .local))
        #expect(!reloaded.isSeen(one, host: .remote("work")), "a seen id is per host")
        #expect(reloaded.isSeen(two, host: .remote("work")))
        #expect(!reloaded.isSeen(surfaced("u-1", agent: "alpha", startedAt: "s2"), host: .local), "and per incarnation")
    }

    @Test func theLedgerKeepsOnlyTheLatestSeenIdsPerHost() {
        let limit = LeoSurfacedFileLedger.perHostLimit
        let files = (0...limit).map { surfaced("u-\($0)", agent: "alpha", startedAt: "s1") }
        let ledger = files.reduce(LeoSurfacedFileLedger()) { $0.markingSeen($1, host: .local) }
        #expect(!ledger.isSeen(files[0], host: .local))
        #expect(ledger.isSeen(files[limit], host: .local))
        #expect(ledger.markingSeen(files[limit], host: .local) == ledger, "marking again is a no-op")
    }

    @Test func unreadableStoredDataReadsAsNothingSeen() {
        let defaults = LeoInMemoryDefaults()
        defaults.set(Data("garbage".utf8), forKey: LeoUserDefaultsSurfacedFileSeenStore.key)
        #expect(LeoUserDefaultsSurfacedFileSeenStore(defaults: defaults).load() == LeoSurfacedFileLedger())
    }

    /// Review #2: seen is per incarnation, so a new incarnation reusing an
    /// id still badges, across a relaunch.
    @Test func aSeenIdDoesNotHideANewIncarnationsFileWithTheSameId() {
        let defaults = LeoInMemoryDefaults()
        let old = surfaced("u-1", agent: "alpha", startedAt: "s1")
        makeModel([row("alpha", "s1", files: [old])], defaults: defaults).markSurfacedFileSeen(old, host: .local)

        let new = surfaced("u-1", agent: "alpha", startedAt: "s2")
        let relaunched = makeModel([row("alpha", "s2", files: [new])], defaults: defaults)
        #expect(relaunched.pendingSurfacedFiles(for: relaunched.snapshot.rows[0]) == [new])
    }

    /// `/state` recovery after a restart doesn't re-badge what was opened.
    @Test func aFileSeenBeforeARelaunchIsNotPendingAfterIt() {
        let defaults = LeoInMemoryDefaults()
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let first = makeModel([row("alpha", "s1", files: [file])], defaults: defaults)
        first.markSurfacedFileSeen(file, host: .local)

        let relaunched = makeModel([row("alpha", "s1", files: [file])], defaults: defaults)
        #expect(relaunched.pendingSurfacedFiles(for: relaunched.snapshot.rows[0]).isEmpty)
    }

    // MARK: No routed open without the user

    /// A surfaced file is never shown through the router by itself: not on
    /// arrival in a snapshot while its agent's tab is focused, not on
    /// focusing that tab later, not on a row click. Only ⌥⌘O or a Surfaced
    /// Files ▸ item does (B-273's background open is the feed's live event).
    @Test func nothingOpensASurfacedFileWithoutAUserAction() {
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1", line: 3)
        let model = makeModel([row("alpha", "s1"), row("beta", "s1")])
        let opened = OpenLog(model)
        focus(model, "alpha")

        // It arrives (the feed's snapshot carries it) while alpha's tab is focused.
        model.receive(LeoSidebarSnapshot(rows: [row("alpha", "s1", files: [file]), row("beta", "s1")], connectivity: .connected, generation: 2))
        model.receiveAttachLinks(LeoAttachLinkState(focused: nil, attachCounts: model.attachLinks.attachCounts))
        focus(model, "beta")
        focus(model, "alpha")
        model.rowClicked(model.snapshot.rows[0])
        model.rowClicked(model.snapshot.rows[0], modifierFlags: .option)
        #expect(opened.files.isEmpty)
        #expect(model.pendingSurfacedFiles(for: model.snapshot.rows[0]) == [file], "badged until the user opens it")

        #expect(model.openNewestSurfacedFile(for: model.snapshot.rows[0]))
        #expect(opened.files == [file])
        #expect(model.pendingSurfacedFiles(for: model.snapshot.rows[0]).isEmpty, "seen once the user opened it")
    }

    // MARK: Menus

    @Test func openSurfacedFileCommandOpensTheNewestPendingElseTheNewest() {
        let older = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let newer = surfaced("u-2", agent: "alpha", startedAt: "s1")
        let model = makeModel([row("alpha", "s1", files: [older, newer])])
        model.markSurfacedFileSeen(newer, host: .local)
        let opened = OpenLog(model)

        #expect(model.openNewestSurfacedFile(for: model.snapshot.rows[0]))
        #expect(opened.files == [older], "the newest still pending first")
        #expect(model.openNewestSurfacedFile(for: model.snapshot.rows[0]))
        #expect(opened.files == [older, newer], "then the newest, to reopen it")
        #expect(!model.openNewestSurfacedFile(for: row("beta", "s1")))
    }

    /// B-046: a partial `/state` merge keeps a live file in `at` order, so
    /// ⌥⌘O picks the baseline's newer file, not the live one.
    @Test func openSurfacedFileAfterAPartialMergePicksTheNewestByTimestamp() {
        let file = { (id: String, minute: Int) in surfaced(id, agent: "alpha", startedAt: "s1", at: "2026-09-24T15:0\(minute):00Z") }
        let live = LeoSurfacedFileIndex.empty.inserting(file("t2", 2)).index
        let state = LeoObservedAgent(
            name: "alpha", status: .running, activity: nil, currentAction: nil, lastActivityAt: nil, startedAt: "s1",
            surfacedFiles: [file("t1", 1), file("t3", 3)]
        )
        let merged = live.merging(state: [state]).attach(to: [row("alpha", "s1")])
        #expect(merged[0].surfacedFiles.map(\.id) == ["t1", "t2", "t3"])
        let model = makeModel(merged)
        let opened = OpenLog(model)

        #expect(model.openNewestSurfacedFile(for: model.snapshot.rows[0]))
        #expect(opened.files.map(\.id) == ["t3"])
    }

    @Test func openingASpecificFileMarksOnlyItSeen() {
        let older = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let newer = surfaced("u-2", agent: "alpha", startedAt: "s1")
        let model = makeModel([row("alpha", "s1", files: [older, newer])])
        let opened = OpenLog(model)
        model.openSurfacedFile(older, for: model.snapshot.rows[0])
        #expect(opened.files == [older])
        #expect(model.pendingSurfacedFiles(for: model.snapshot.rows[0]) == [newer])
    }

    @Test func theMenuCommandIsEnabledOnlyForASelectedRowWithSurfacedFiles() {
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1")
        #expect(LeoMenuCommands.canOpenSurfacedFile(hasLeoSession: true, selected: row("alpha", "s1", files: [file])))
        #expect(!LeoMenuCommands.canOpenSurfacedFile(hasLeoSession: true, selected: row("alpha", "s1")))
        #expect(!LeoMenuCommands.canOpenSurfacedFile(hasLeoSession: true, selected: nil))
        #expect(!LeoMenuCommands.canOpenSurfacedFile(hasLeoSession: false, selected: row("alpha", "s1", files: [file])))
    }

    /// ⌥⌘O: unused by Ghostty's default keybinds and every other menu item.
    @Test func theOpenSurfacedFileItemHasAShortcutNoOtherMenuItemUses() throws {
        let items = try LeoMenuXib.shortcuts()
        let item = try #require(items.first { $0.action == "openLeoSurfacedFile:" })
        #expect(item.title == "Open Surfaced File")
        #expect(item.shortcut == "⌥⌘o")
        let clashes = items.filter { $0.action != item.action && $0.shortcut == item.shortcut }
        #expect(clashes.isEmpty, "\(clashes.map(\.title))")
    }

    /// The agent restarted under the same name after the menu was built:
    /// the old incarnation's file doesn't open, then or after the stat.
    @Test func aMenuOpenForAnIncarnationTheRowNoLongerShowsDoesNothing() {
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let model = makeModel([row("alpha", "s1", files: [file])])
        let opened = OpenLog(model)
        let staleRow = model.snapshot.rows[0]
        let stillWanted = model.surfacedOpenGuard(for: file, row: staleRow)
        #expect(stillWanted())
        model.receive(LeoSidebarSnapshot(rows: [row("alpha", "s2")], connectivity: .connected, generation: 2))
        #expect(!stillWanted())
        model.openSurfacedFile(file, for: staleRow)
        #expect(opened.files.isEmpty)
    }

    @Test func nothingOpensWhileDisconnected() {
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let model = makeModel([row("alpha", "s1", files: [file])], connectivity: .disconnected(reason: "gone", isRetrying: false))
        let opened = OpenLog(model)
        model.openSurfacedFile(file, for: model.snapshot.rows[0])
        #expect(opened.files.isEmpty)
    }

    // MARK: Presentation

    @Test func theRowIndicatorCountsPendingFilesAndListsTheirReasons() throws {
        let files = [
            surfaced("u-1", agent: "alpha", startedAt: "s1", path: "a/one.swift", reason: "First"),
            surfaced("u-2", agent: "alpha", startedAt: "s1", path: "two.md"),
        ]
        let indicator = try #require(LeoSurfacedFilesIndicator(pending: files))
        #expect(indicator.countText == "2")
        #expect(indicator.tooltip.contains("one.swift\u{2069} — First"))
        #expect(indicator.tooltip.contains("two.md"))
        #expect(indicator.accessibilityLabel == "2 surfaced files")
        #expect(LeoSurfacedFilesIndicator(pending: [files[0]])?.accessibilityLabel == "1 surfaced file")
        #expect(LeoSurfacedFilesIndicator(pending: []) == nil)
    }

    // MARK: Helpers

    private func makeModel(
        _ rows: [LeoAgentRow], defaults: UserDefaults = LeoInMemoryDefaults(), connectivity: LeoConnectivity = .connected
    ) -> LeoSidebarModel {
        LeoSidebarModel(
            snapshot: LeoSidebarSnapshot(rows: rows, connectivity: connectivity, generation: 1),
            surfacedSeenStore: LeoUserDefaultsSurfacedFileSeenStore(defaults: defaults)
        )
    }

    private func id(_ name: String) -> LeoAgentRow.ID { LeoAgentRow.ID(host: .local, name: name) }

    /// Focus lands on an attach surface of `name` (one live attach), as the attach
    /// coordinator's link state reports it.
    private func focus(_ model: LeoSidebarModel, _ name: String) {
        let attaches = model.attachLinks.attachCounts.merging([id(name): max(1, model.attachCount(for: id(name)))]) { _, new in new }
        model.receiveAttachLinks(LeoAttachLinkState(focused: id(name), attachCounts: attaches))
    }

    private func row(_ name: String, _ startedAt: String, files: [LeoSurfacedFile] = []) -> LeoAgentRow {
        LeoAgentRow(host: .local, name: name, template: nil, status: .running, activity: .unknown, actionDetail: nil, startedAt: startedAt)
            .withSurfacedFiles(files)
    }
}

/// Records open requests, marking each seen as the opener does once the
/// file opens.
@MainActor private final class OpenLog {
    private(set) var files: [LeoSurfacedFile] = []

    init(_ model: LeoSidebarModel) {
        model.surfacedFileOpenRequested = { [weak self, weak model] file, row, _ in
            self?.files.append(file)
            model?.markSurfacedFileSeen(file, host: row.host)
        }
    }
}
