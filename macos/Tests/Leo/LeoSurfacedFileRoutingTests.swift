import AppKit
import Foundation
import Testing

@testable import Ghostty

/// B-013 on the main actor: which surfaced files are pending (unseen), when
/// one opens by itself (arrival while its agent's tab is focused; focusing
/// or clicking that agent later), what the menus open, and that seen ids
/// persist per host, bounded.
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

    // MARK: Arrival

    @Test func anArrivalForTheFocusedAgentOpensAndIsSeen() {
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1", line: 12)
        let model = makeModel([row("alpha", "s1")])
        let opened = OpenLog(model)
        focus(model, "alpha")
        #expect(opened.files.isEmpty)

        model.fileSurfaced(file, host: .local)
        #expect(opened.files == [file])
        // The feed's snapshot carrying it lands after the callback.
        model.receive(LeoSidebarSnapshot(rows: [row("alpha", "s1", files: [file])], connectivity: .connected, generation: 2))
        #expect(model.pendingSurfacedFiles(for: model.snapshot.rows[0]).isEmpty)
    }

    @Test func anArrivalForAnUnfocusedAgentIsQueued() {
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let model = makeModel([row("alpha", "s1", files: [file]), row("beta", "s1")])
        let opened = OpenLog(model)
        focus(model, "beta")

        model.fileSurfaced(file, host: .local)
        #expect(opened.files.isEmpty)
        #expect(model.pendingSurfacedFiles(for: model.snapshot.rows[0]) == [file])
    }

    @Test func anArrivalForAnotherIncarnationOfTheFocusedNameNeverOpens() {
        let model = makeModel([row("alpha", "s2")])
        let opened = OpenLog(model)
        focus(model, "alpha")
        model.fileSurfaced(surfaced("u-1", agent: "alpha", startedAt: "s1"), host: .local)
        model.fileSurfaced(surfaced("u-2", agent: "alpha", startedAt: "s2"), host: .remote("work"))
        #expect(opened.files.isEmpty)
    }

    @Test func nothingOpensWhileDisconnected() {
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let model = makeModel([row("alpha", "s1", files: [file])], connectivity: .disconnected(reason: "gone", isRetrying: false))
        let opened = OpenLog(model)
        focus(model, "alpha")
        model.fileSurfaced(file, host: .local)
        #expect(opened.files.isEmpty)
    }

    // MARK: Incarnation of the focused tab (security review #2)

    /// The agent restarted under the same name while its old tab stayed
    /// focused: the new incarnation's file must not open in that tab's window.
    @Test func anArrivalAfterARestartUnderTheFocusedTabIsQueued() {
        let model = makeModel([row("alpha", "s1")])
        let opened = OpenLog(model)
        focus(model, "alpha")
        model.receive(LeoSidebarSnapshot(rows: [row("alpha", "s2")], connectivity: .connected, generation: 2))

        let file = surfaced("u-1", agent: "alpha", startedAt: "s2")
        model.fileSurfaced(file, host: .local)
        #expect(opened.files.isEmpty)
        model.receive(LeoSidebarSnapshot(rows: [row("alpha", "s2", files: [file])], connectivity: .connected, generation: 3))
        #expect(model.pendingSurfacedFiles(for: model.snapshot.rows[0]) == [file])
    }

    @Test func anArrivalForAFocusedAgentOfUnknownIncarnationIsQueued() {
        let model = makeModel([LeoAgentRow(host: .local, name: "alpha", template: nil, status: .running, activity: .unknown, actionDetail: nil)])
        let opened = OpenLog(model)
        focus(model, "alpha")
        model.fileSurfaced(surfaced("u-1", agent: "alpha", startedAt: "s1"), host: .local)
        #expect(opened.files.isEmpty)
    }

    /// Focus reported before the first list: the row's first incarnation
    /// is the tab's.
    @Test func focusBeforeTheFirstListAdoptsTheRowsIncarnation() {
        let model = makeModel([])
        let opened = OpenLog(model)
        focus(model, "alpha")
        model.receive(LeoSidebarSnapshot(rows: [row("alpha", "s1")], connectivity: .connected, generation: 2))
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1")
        model.fileSurfaced(file, host: .local)
        #expect(opened.files == [file])
    }

    @Test func automaticOpensAreSeenOnlyOnceTheOpenerAcceptsThem() {
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let model = makeModel([row("alpha", "s1", files: [file])])
        let opened = OpenLog(model, rejectsAuto: true)
        focus(model, "alpha")
        #expect(opened.modes == [.automatic])
        #expect(model.pendingSurfacedFiles(for: model.snapshot.rows[0]) == [file], "a skipped auto-open keeps its badge")
        model.openSurfacedFile(file, for: model.snapshot.rows[0])
        #expect(opened.modes == [.automatic, .manual])
        #expect(model.pendingSurfacedFiles(for: model.snapshot.rows[0]).isEmpty)
    }

    // MARK: The tab's incarnation on refocus and click (re-review #1)

    /// The focused tab's agent restarted; the user looks away and back at
    /// that same old tab: the new incarnation's file stays badged.
    @Test func refocusingATabFromBeforeARestartOpensNothing() {
        let model = makeModel([row("alpha", "s1")])
        let opened = OpenLog(model)
        focus(model, "alpha")
        model.focusedAgentChanged(nil)
        let file = surfaced("u-1", agent: "alpha", startedAt: "s2")
        model.receive(LeoSidebarSnapshot(rows: [row("alpha", "s2", files: [file])], connectivity: .connected, generation: 2))
        model.focusedAgentChanged(id("alpha"))
        #expect(opened.files.isEmpty)
        #expect(model.pendingSurfacedFiles(for: model.snapshot.rows[0]) == [file])
    }

    @Test func clickingTheRowOfARestartedAgentWhoseOldTabIsFocusedOpensNothing() {
        let model = makeModel([row("alpha", "s1")])
        let opened = OpenLog(model)
        focus(model, "alpha")
        let file = surfaced("u-1", agent: "alpha", startedAt: "s2")
        model.receive(LeoSidebarSnapshot(rows: [row("alpha", "s2", files: [file])], connectivity: .connected, generation: 2))
        model.rowClicked(model.snapshot.rows[0])
        #expect(opened.files.isEmpty)
        #expect(model.openNewestSurfacedFile(for: model.snapshot.rows[0]), "still reachable from the menus")
        #expect(opened.modes == [.manual])
    }

    /// Once the old tabs are gone, a tab attached to the new incarnation
    /// opens its files again.
    @Test func aFreshAttachAfterTheOldTabsCloseOpensAgain() {
        let model = makeModel([row("alpha", "s1")])
        let opened = OpenLog(model)
        focus(model, "alpha")
        let file = surfaced("u-1", agent: "alpha", startedAt: "s2")
        model.receive(LeoSidebarSnapshot(rows: [row("alpha", "s2", files: [file])], connectivity: .connected, generation: 2))
        model.receiveAttachLinks(LeoAttachLinkState(focused: nil, tabCounts: [:]))
        model.focusedAgentChanged(nil)
        focus(model, "alpha")
        #expect(opened.files == [file])
    }

    /// The attach coordinator reports focus before the link state that
    /// shows the new tab: the open waits for it.
    @Test func aNewTabsFocusReportedBeforeItsLinkStateStillOpens() {
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let model = makeModel([row("alpha", "s1", files: [file])])
        let opened = OpenLog(model)
        model.focusedAgentChanged(id("alpha"))
        #expect(opened.files.isEmpty)
        model.receiveAttachLinks(LeoAttachLinkState(focused: id("alpha"), tabCounts: [id("alpha"): 1]))
        #expect(opened.files == [file])
        model.receiveAttachLinks(LeoAttachLinkState(focused: id("alpha"), tabCounts: [id("alpha"): 2]))
        #expect(opened.files == [file], "once")
    }

    /// What an auto-open re-checks after its stat: the same agent's tab is
    /// focused and still shows the file's incarnation.
    @Test func theAutoOpenGuardFailsOnceFocusOrIncarnationMoves() {
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let model = makeModel([row("alpha", "s1", files: [file]), row("beta", "s1")])
        focus(model, "alpha")
        let stillWanted = model.surfacedAutoOpenGuard(for: file, row: model.snapshot.rows[0])
        #expect(stillWanted())
        focus(model, "beta")
        #expect(!stillWanted(), "focus moved to another agent")

        let restarted = makeModel([row("alpha", "s1", files: [file])])
        focus(restarted, "alpha")
        let guardBeforeRestart = restarted.surfacedAutoOpenGuard(for: file, row: restarted.snapshot.rows[0])
        restarted.receive(LeoSidebarSnapshot(rows: [row("alpha", "s2")], connectivity: .connected, generation: 2))
        #expect(!guardBeforeRestart(), "the agent restarted")
    }

    // MARK: Focus and click

    @Test func focusingAnAgentOpensItsNewestPendingFileAndLeavesTheRest() {
        let older = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let newer = surfaced("u-2", agent: "alpha", startedAt: "s1")
        let model = makeModel([row("alpha", "s1", files: [older, newer])])
        let opened = OpenLog(model)

        focus(model, "alpha")
        #expect(opened.files == [newer])
        #expect(model.pendingSurfacedFiles(for: model.snapshot.rows[0]) == [older])

        focus(model, "alpha")
        #expect(opened.files == [newer], "focus that didn't change opens nothing")
    }

    @Test func focusingAnAgentWithNothingPendingOpensNothing() {
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let model = makeModel([row("alpha", "s1", files: [file])])
        model.markSurfacedFileSeen(file, host: .local)
        let opened = OpenLog(model)
        focus(model, "alpha")
        #expect(opened.files.isEmpty)
    }

    @Test func clickingARowWithoutAnAttachOpensItsNewestPendingFile() {
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let model = makeModel([row("alpha", "s1", files: [file])])
        let opened = OpenLog(model)
        model.rowClicked(model.snapshot.rows[0])
        #expect(opened.files == [file])
    }

    /// A row with a live attach brings it forward; the focus change that
    /// follows opens the file, once.
    @Test func clickingARowWithAnUnfocusedAttachLeavesTheOpenToFocus() {
        let file = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let model = makeModel([row("alpha", "s1", files: [file])])
        model.receiveAttachLinks(LeoAttachLinkState(focused: nil, tabCounts: [id("alpha"): 1]))
        let opened = OpenLog(model)
        var focused: [String] = []
        model.focusExistingRequested = { focused.append($0.name) }
        model.rowClicked(model.snapshot.rows[0])
        #expect(focused == ["alpha"])
        #expect(opened.files.isEmpty)
        focus(model, "alpha")
        #expect(opened.files == [file])
    }

    /// A double-click's first click opens one; the attach it makes must
    /// not open the next pending one on focus.
    @Test func theAttachAfterAClickOpenDoesNotOpenAnother() {
        let older = surfaced("u-1", agent: "alpha", startedAt: "s1")
        let newer = surfaced("u-2", agent: "alpha", startedAt: "s1")
        let model = makeModel([row("alpha", "s1", files: [older, newer])])
        let opened = OpenLog(model)
        model.rowClicked(model.snapshot.rows[0])
        model.rowClicked(model.snapshot.rows[0])
        focus(model, "alpha")
        #expect(opened.files == [newer])

        // A later visit opens the next one.
        model.focusedAgentChanged(nil)
        focus(model, "alpha")
        #expect(opened.files == [newer, older])
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
    /// coordinator reports it: link state first, then the focused identity.
    private func focus(_ model: LeoSidebarModel, _ name: String) {
        let tabs = model.attachLinks.tabCounts.merging([id(name): max(1, model.tabCount(for: id(name)))]) { _, new in new }
        model.receiveAttachLinks(LeoAttachLinkState(focused: id(name), tabCounts: tabs))
        model.focusedAgentChanged(id(name))
    }

    private func row(_ name: String, _ startedAt: String, files: [LeoSurfacedFile] = []) -> LeoAgentRow {
        LeoAgentRow(host: .local, name: name, template: nil, status: .running, activity: .unknown, actionDetail: nil, startedAt: startedAt)
            .withSurfacedFiles(files)
    }
}

/// Records open requests, marking each seen as the opener does once the
/// file opens -- an automatic one only unless `rejectsAuto`.
@MainActor private final class OpenLog {
    private(set) var files: [LeoSurfacedFile] = []
    private(set) var modes: [LeoSurfacedOpenMode] = []

    init(_ model: LeoSidebarModel, rejectsAuto: Bool = false) {
        model.surfacedFileOpenRequested = { [weak self, weak model] file, row, mode in
            self?.files.append(file)
            self?.modes.append(mode)
            if mode == .manual || !rejectsAuto { model?.markSurfacedFileSeen(file, host: row.host) }
        }
    }
}
