import AppKit
import Foundation
import Testing

@testable import Ghostty

/// B-013 on the main actor: which surfaced files are pending (unseen), that
/// none ever opens by itself (D-088), what the menus open, and that seen
/// ids persist per host, bounded.
@MainActor
struct LeoSurfacedFileRoutingTests {
    // MARK: Seen ledger

    @Test func seenIdsPersistPerHost() {
        let defaults = LeoInMemoryDefaults()
        let store = LeoUserDefaultsSurfacedFileSeenStore(defaults: defaults)
        store.save(LeoSurfacedFileLedger().markingSeen("u-1", host: .local).markingSeen("u-2", host: .remote("work")))

        let reloaded = LeoUserDefaultsSurfacedFileSeenStore(defaults: defaults).load()
        #expect(reloaded.isSeen("u-1", host: .local))
        #expect(!reloaded.isSeen("u-1", host: .remote("work")), "a seen id is per host")
        #expect(reloaded.isSeen("u-2", host: .remote("work")))
    }

    @Test func theLedgerKeepsOnlyTheLatestSeenIdsPerHost() {
        let limit = LeoSurfacedFileLedger.perHostLimit
        let ledger = (0...limit).reduce(LeoSurfacedFileLedger()) { $0.markingSeen("u-\($1)", host: .local) }
        #expect(!ledger.isSeen("u-0", host: .local))
        #expect(ledger.isSeen("u-\(limit)", host: .local))
        #expect(ledger.markingSeen("u-\(limit)", host: .local) == ledger, "marking again is a no-op")
    }

    @Test func unreadableStoredDataReadsAsNothingSeen() {
        let defaults = LeoInMemoryDefaults()
        defaults.set(Data("garbage".utf8), forKey: LeoUserDefaultsSurfacedFileSeenStore.key)
        #expect(LeoUserDefaultsSurfacedFileSeenStore(defaults: defaults).load() == LeoSurfacedFileLedger())
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

    // MARK: No auto-open (D-088)

    /// A surfaced file never opens by itself: not on arrival while its
    /// agent's tab is focused, not on focusing that tab later, not on a
    /// row click. Only ⌥⌘O or a Surfaced Files ▸ item opens it.
    @Test func nothingOpensASurfacedFileWithoutAUserAction() {
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1", line: 3)
        let model = makeModel([row("alpha", "s1"), row("beta", "s1")])
        let opened = OpenLog(model)
        focus(model, "alpha")

        // It arrives (the feed's snapshot carries it) while alpha's tab is focused.
        model.receive(LeoSidebarSnapshot(rows: [row("alpha", "s1", files: [file]), row("beta", "s1")], connectivity: .connected, generation: 2))
        model.receiveAttachLinks(LeoAttachLinkState(focused: nil, tabCounts: model.attachLinks.tabCounts))
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

    /// Focus lands on an attach tab of `name` (one live tab), as the attach
    /// coordinator's link state reports it.
    private func focus(_ model: LeoSidebarModel, _ name: String) {
        let tabs = model.attachLinks.tabCounts.merging([id(name): max(1, model.tabCount(for: id(name)))]) { _, new in new }
        model.receiveAttachLinks(LeoAttachLinkState(focused: id(name), tabCounts: tabs))
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
