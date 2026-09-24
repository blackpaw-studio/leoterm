import Foundation
import Testing

@testable import Ghostty

/// B-010: sort by last activity or name, pinned agents, collapsed sections.
@MainActor struct LeoSidebarSortPinTests {
    // MARK: Sort

    @Test func lastActivitySortsNewestFirst() {
        let rows = [row("a", at: 10), row("b", at: 30), row("c", at: 20)]
        #expect(LeoSidebarLayout.sorted(rows, by: .lastActivity).map(\.name) == ["b", "c", "a"])
    }

    @Test func lastActivityTiesFallBackToName() {
        let rows = [row("zed", at: 10), row("Alpha", at: 10), row("beta", at: 10)]
        #expect(LeoSidebarLayout.sorted(rows, by: .lastActivity).map(\.name) == ["Alpha", "beta", "zed"])
    }

    @Test func missingTimestampsSortAfterKnownOnesByName() {
        let rows = [row("zed"), row("old", at: 1), row("abc"), row("new", at: 5)]
        #expect(LeoSidebarLayout.sorted(rows, by: .lastActivity).map(\.name) == ["new", "old", "abc", "zed"])
    }

    @Test func nameSortIgnoresActivityAndCase() {
        let rows = [row("b", at: 99), row("C"), row("a", at: 1)]
        #expect(LeoSidebarLayout.sorted(rows, by: .name).map(\.name) == ["a", "b", "C"])
    }

    @Test func sectionsKeepStatusOrderAndSortWithinEach() {
        let rows = [
            row("s-old", status: .stopped, at: 1), row("r-old", at: 2), row("s-new", status: .stopped, at: 9),
            row("r-new", at: 8), row("boot", status: .starting)
        ]
        let sections = LeoSidebarLayout.sections(rows: rows, query: "", preferences: .init(), host: .local)
        #expect(sections.map(\.title) == ["Running", "Starting", "Stopped"])
        #expect(sections.map { $0.rows.map(\.name) } == [["r-new", "r-old"], ["boot"], ["s-new", "s-old"]])
    }

    @Test func nameSortOrderAppliesWithinSections() {
        let rows = [row("b", at: 9), row("a", at: 1)]
        let sections = LeoSidebarLayout.sections(rows: rows, query: "", preferences: .init(sortOrder: .name), host: .local)
        #expect(sections.first?.rows.map(\.name) == ["a", "b"])
    }

    @Test func defaultSortIsLastActivity() {
        #expect(LeoSidebarPreferences().sortOrder == .lastActivity)
        #expect(makeModel([]).preferences.sortOrder == .lastActivity)
    }

    // MARK: Pinned section

    @Test func pinnedAgentsFormATopSectionSortedTheSameWay() {
        let rows = [row("r1", at: 5), row("s1", status: .stopped, at: 9), row("r2", at: 7), row("r3", at: 1)]
        let prefs = LeoSidebarPreferences(pinned: [id("r1"), id("s1"), id("r3")])
        let sections = LeoSidebarLayout.sections(rows: rows, query: "", preferences: prefs, host: .local)
        #expect(sections.map(\.title) == ["Pinned", "Running"])
        #expect(sections.map { $0.rows.map(\.name) } == [["s1", "r1", "r3"], ["r2"]])
    }

    @Test func pinsAreKeyedByHost() {
        let remote = LeoAgentRow(host: .remote("box"), name: "r1", template: nil, status: .running, activity: .idle, actionDetail: nil)
        let prefs = LeoSidebarPreferences(pinned: [id("r1")])
        let sections = LeoSidebarLayout.sections(rows: [remote], query: "", preferences: prefs, host: .remote("box"))
        #expect(sections.map(\.title) == ["Running"])
    }

    @Test func togglePinPersistsThroughTheStore() {
        let store = LeoInMemorySidebarPreferencesStore()
        let model = makeModel([row("a"), row("b")], store: store)
        model.togglePin(id("b"))
        #expect(model.isPinned(id("b")))
        #expect(model.sections.first?.title == "Pinned")

        let reloaded = makeModel([row("a"), row("b")], store: store)
        #expect(reloaded.isPinned(id("b")))
        #expect(reloaded.sections.map { $0.rows.map(\.name) } == [["b"], ["a"]])

        reloaded.togglePin(id("b"))
        #expect(!makeModel([], store: store).isPinned(id("b")))
    }

    @Test func aPinnedAgentThatDisappearsStaysStoredAndReturnsPinned() {
        let store = LeoInMemorySidebarPreferencesStore()
        let model = makeModel([row("a"), row("gone")], store: store)
        model.togglePin(id("gone"))

        model.receive(LeoSidebarSnapshot(rows: [row("a")], connectivity: .connected, generation: 2))
        #expect(model.sections.map(\.title) == ["Running"])
        #expect(model.isPinned(id("gone")))
        #expect(store.load().pinned.contains(id("gone")))

        model.receive(LeoSidebarSnapshot(rows: [row("a"), row("gone")], connectivity: .connected, generation: 3))
        #expect(model.sections.map { $0.rows.map(\.name) } == [["gone"], ["a"]])
    }

    @Test func sortOrderPersistsThroughTheStore() {
        let store = LeoInMemorySidebarPreferencesStore()
        makeModel([], store: store).setSortOrder(.name)
        #expect(makeModel([], store: store).preferences.sortOrder == .name)
    }

    // MARK: Collapse

    @Test func collapsedSectionKeepsItsHeaderButHidesRows() {
        let model = makeModel([row("r"), row("s", status: .stopped)])
        model.toggleCollapsed("running")
        #expect(model.sections.map(\.title) == ["Running", "Stopped"])
        #expect(model.sections.map(\.isCollapsed) == [true, false])
        #expect(model.visibleRows.map(\.name) == ["s"])
        model.toggleCollapsed("running")
        #expect(model.visibleRows.map(\.name) == ["r", "s"])
    }

    @Test func collapseIsPersistedPerHost() {
        let store = LeoInMemorySidebarPreferencesStore()
        makeModel([row("r")], store: store).toggleCollapsed("running")

        #expect(makeModel([row("r")], store: store).sections.first?.isCollapsed == true)
        let remote = LeoAgentRow(host: .remote("box"), name: "r", template: nil, status: .running, activity: .idle, actionDetail: nil)
        #expect(makeModel([remote], store: store).sections.first?.isCollapsed == false)
    }

    @Test func collapsingEverySectionStillShowsTheHeadersNotNoMatches() {
        let model = makeModel([row("r"), row("s", status: .stopped)])
        model.toggleCollapsed("running")
        model.toggleCollapsed("stopped")
        #expect(model.visibleRows.isEmpty)
        #expect(!model.showsNoMatches)
        #expect(model.sections.map(\.title) == ["Running", "Stopped"])
    }

    @Test func noMatchesDependsOnlyOnTheFilter() {
        let model = makeModel([row("r")])
        #expect(!model.showsNoMatches)
        model.query = "zzz"
        #expect(model.showsNoMatches)
        #expect(!makeModel([]).showsNoMatches)
    }

    @Test func pinnedSectionCanCollapse() {
        let model = makeModel([row("a"), row("b")])
        model.togglePin(id("a"))
        model.toggleCollapsed(LeoSidebarLayout.pinnedSectionID)
        #expect(model.visibleRows.map(\.name) == ["b"])
    }

    @Test func aNonEmptyFilterShowsMatchesRegardlessOfCollapse() {
        let model = makeModel([row("web-app", status: .stopped), row("apple"), row("zzz")])
        model.toggleCollapsed("running")
        model.toggleCollapsed("stopped")
        model.query = "app"
        #expect(model.sections.allSatisfy { !$0.isCollapsed })
        #expect(model.visibleRows.map(\.name) == ["apple", "web-app"])
    }

    @Test func whileFilteringTheFirstDisplayedRowIsTheReturnTarget() {
        let model = makeModel([row("web-app", at: 9), row("apple", status: .stopped, at: 1)])
        model.togglePin(id("web-app"))
        model.toggleCollapsed("stopped")
        model.query = "app"
        #expect(model.sections.first?.rows.first?.name == "apple")
        model.searchSubmit()
        #expect(model.selection == id("apple"))
    }

    @Test func returnWithoutAFilterSkipsCollapsedSections() {
        let model = makeModel([row("r"), row("s", status: .stopped)])
        model.toggleCollapsed("running")
        model.searchSubmit()
        #expect(model.selection == id("s"))
    }

    @Test func revealExpandsTheSectionHoldingARow() {
        let model = makeModel([row("a"), row("b")])
        model.togglePin(id("a"))
        model.toggleCollapsed(LeoSidebarLayout.pinnedSectionID)
        model.toggleCollapsed("running")
        model.reveal(id("b"))
        #expect(model.sections.map(\.isCollapsed) == [true, false])
    }

    @Test func orderedRowsFollowTheDisplayIgnoringCollapseAndFilter() {
        let model = makeModel([row("r", at: 1), row("s", status: .stopped), row("p", status: .stopped)])
        model.togglePin(id("p"))
        model.toggleCollapsed("running")
        model.query = "s"
        #expect(model.orderedRows.map(\.name) == ["p", "r", "s"])
    }

    // MARK: Store codec

    @Test func preferencesRoundTripThroughTheirEncoding() throws {
        let prefs = LeoSidebarPreferences(
            sortOrder: .name,
            pinned: [id("a"), LeoAgentRow.ID(host: .remote("box"), name: "b")],
            collapsed: [.local: ["running"], .remote("box"): [LeoSidebarLayout.pinnedSectionID]]
        )
        let data = try #require(prefs.encoded())
        #expect(LeoSidebarPreferences.decode(data) == prefs)
    }

    @Test func missingOrCorruptPreferencesDecodeToDefaults() {
        #expect(LeoSidebarPreferences.decode(nil) == LeoSidebarPreferences())
        #expect(LeoSidebarPreferences.decode(Data("not json".utf8)) == LeoSidebarPreferences())
        #expect(LeoSidebarPreferences.decode(Data(#"{"sortOrder":"bogus"}"#.utf8)) == LeoSidebarPreferences())
    }

    // MARK: Menu

    @Test func pinMenuTitleAndEnablement() {
        #expect(LeoMenuCommands.pinToggleTitle(isPinned: false) == "Pin Agent")
        #expect(LeoMenuCommands.pinToggleTitle(isPinned: true) == "Unpin Agent")
        let selected = LeoRowActionAvailability(status: .running, isPending: false)
        #expect(LeoMenuCommands.canTogglePin(.init(hasLeoSession: true, availability: selected)))
        #expect(!LeoMenuCommands.canTogglePin(.init(hasLeoSession: true, availability: nil)))
        #expect(!LeoMenuCommands.canTogglePin(.init(hasLeoSession: false, availability: selected)))
    }

    /// ⌥⌘P: unused by Ghostty's default keybinds (Config.zig binds only
    /// ⇧⌘P, the command palette) and by every other menu item.
    @Test func thePinMenuItemHasAShortcutNoOtherMenuItemUses() throws {
        let items = try LeoMenuXib.shortcuts()
        let pin = try #require(items.first { $0.action == "toggleSelectedLeoAgentPin:" })
        #expect(pin.title == "Pin Agent")
        #expect(pin.shortcut == "⌥⌘p")
        let clashes = items.filter { $0.action != pin.action && $0.shortcut == pin.shortcut }
        #expect(clashes.isEmpty, "\(clashes.map(\.title))")
    }

    // MARK: Helpers

    private func makeModel(_ rows: [LeoAgentRow], store: LeoInMemorySidebarPreferencesStore = .init()) -> LeoSidebarModel {
        LeoSidebarModel(
            snapshot: LeoSidebarSnapshot(rows: rows, connectivity: .connected, generation: 1),
            preferencesStore: store
        )
    }

    private func id(_ name: String) -> LeoAgentRow.ID { LeoAgentRow.ID(host: .local, name: name) }

    private func row(_ name: String, status: LeoAgentStatus = .running, at seconds: TimeInterval? = nil) -> LeoAgentRow {
        LeoAgentRow(
            host: .local, name: name, template: nil, status: status, activity: .idle, actionDetail: nil,
            lastActivityAt: seconds.map { Date(timeIntervalSince1970: $0) }
        )
    }
}
