import Foundation
import Testing

@testable import Ghostty

/// Needs You on top of the status layout, and the opt-in grouping by
/// attention (Agents ▸ Group By).
@MainActor struct LeoSidebarGroupingTests {
    private let byStatus = LeoSidebarPreferences()
    private let byAttention = LeoSidebarPreferences(groupBy: .attention)

    // MARK: Status mode

    @Test func needsInputAndErroredRowsLeadAboveEveryStatusSection() {
        let rows = [
            row("run"), row("asking", attention: .needsInput), row("broken", attention: .errored),
            row("off", status: .stopped), row("done", attention: .finished)
        ]
        let sections = layout(rows, byStatus)
        #expect(sections.map(\.title) == ["Needs You", "Running", "Stopped"])
        #expect(Set(sections[0].rows.map(\.name)) == ["asking", "broken"])
        #expect(Set(sections[1].rows.map(\.name)) == ["run", "done"])
    }

    @Test func needsYouBeatsPinnedAndStatusAndEachAgentAppearsOnce() {
        let rows = [row("pinned-asking", attention: .needsInput), row("pinned-calm"), row("stopped-asking", status: .stopped, attention: .needsInput)]
        let prefs = LeoSidebarPreferences(pinned: [id("pinned-asking"), id("pinned-calm")])
        let sections = layout(rows, prefs)
        #expect(sections.map(\.title) == ["Needs You", "Pinned"])
        #expect(Set(sections[0].rows.map(\.name)) == ["pinned-asking", "stopped-asking"])
        #expect(sections[1].rows.map(\.name) == ["pinned-calm"])
        #expect(sections.flatMap(\.rows).count == 3)
    }

    @Test func needsYouIsHiddenWhenEmptyAndFixedOpenWithACount() {
        #expect(layout([row("a")], byStatus).map(\.title) == ["Running"])
        let section = layout([row("a", attention: .needsInput)], byStatus)[0]
        #expect(section.id == LeoSidebarLayout.needsYouSectionID)
        #expect(!section.isCollapsible)
        #expect(section.showsCount)
        #expect(section.isAlert)
    }

    @Test func needsYouCannotBeCollapsedEvenIfStoredAsCollapsed() {
        let prefs = LeoSidebarPreferences(collapsed: [.local: [LeoSidebarLayout.needsYouSectionID]])
        let section = layout([row("a", attention: .needsInput)], prefs)[0]
        #expect(!section.isCollapsed)
    }

    @Test func statusSectionsStayCollapsibleWithoutCounts() {
        let section = layout([row("a")], byStatus)[0]
        #expect(section.isCollapsible)
        #expect(!section.showsCount)
    }

    @Test func aClearedAttentionReturnsTheRowToItsOwnSection() {
        let asking = layout([row("a", attention: .needsInput)], byStatus)
        #expect(asking.map(\.title) == ["Needs You"])
        #expect(layout([row("a", attention: .working)], byStatus).map(\.title) == ["Running"])
    }

    // MARK: Attention mode

    @Test func attentionModeSplitsIntoNeedsYouWorkingFinishedAndIdleStopped() {
        let rows = [
            row("ask", attention: .needsInput), row("err", attention: .errored),
            row("work", attention: .working), row("act", activity: .working),
            row("compact", compaction: LeoRowCompaction(trigger: .auto)),
            row("fin", attention: .finished),
            row("idle"), row("off", status: .stopped), row("boot", status: .starting), row("odd", status: .unknown("x"))
        ]
        let sections = layout(rows, byAttention)
        #expect(sections.map(\.title) == ["Needs You", "Working", "Finished", "Idle & Stopped"])
        #expect(Set(sections[0].rows.map(\.name)) == ["ask", "err"])
        #expect(Set(sections[1].rows.map(\.name)) == ["work", "act", "compact"])
        #expect(sections[2].rows.map(\.name) == ["fin"])
        #expect(Set(sections[3].rows.map(\.name)) == ["idle", "off", "boot", "odd"])
    }

    @Test func aStoppedAgentWithStaleWorkingActivityIsNotWorking() {
        let sections = layout([row("off", status: .stopped, activity: .working)], byAttention)
        #expect(sections.map(\.title) == ["Idle & Stopped"])
    }

    @Test func attentionModeKeepsPinnedUnderNeedsYouAndAheadOfTheRest() {
        let rows = [row("ask", attention: .needsInput), row("pin", attention: .working), row("work", attention: .working)]
        let prefs = LeoSidebarPreferences(groupBy: .attention, pinned: [id("pin"), id("ask")])
        let sections = layout(rows, prefs)
        #expect(sections.map(\.title) == ["Needs You", "Pinned", "Working"])
        #expect(sections[1].rows.map(\.name) == ["pin"])
        #expect(sections[2].rows.map(\.name) == ["work"])
    }

    @Test func attentionSectionsShowCountsAndOnlyNeedsYouIsFixed() {
        let rows = [row("ask", attention: .needsInput), row("work", attention: .working), row("idle")]
        let sections = layout(rows, byAttention)
        #expect(sections.allSatisfy { $0.showsCount })
        #expect(sections.map(\.isCollapsible) == [false, true, true])
    }

    @Test func idleAndStoppedStartsCollapsedAndExpandingIsRemembered() {
        let rows = [row("idle")]
        #expect(layout(rows, byAttention)[0].isCollapsed)
        let expanded = byAttention.setting(LeoSidebarLayout.idleStoppedSectionID, collapsed: false, host: .local)
        #expect(!layout(rows, expanded)[0].isCollapsed)
        let collapsedAgain = expanded.setting(LeoSidebarLayout.idleStoppedSectionID, collapsed: true, host: .local)
        #expect(layout(rows, collapsedAgain)[0].isCollapsed)
        #expect(collapsedAgain == byAttention, "back to the default leaves no trace")
    }

    @Test func otherAttentionSectionsStartOpen() {
        let sections = layout([row("work", attention: .working), row("fin", attention: .finished)], byAttention)
        #expect(sections.map(\.isCollapsed) == [false, false])
    }

    @Test func collapsedIdleAndStoppedHidesItsRowsFromTheVisibleList() {
        let rows = [row("work", attention: .working), row("idle")]
        let visible = LeoSidebarLayout.visibleRows(rows: rows, query: "", preferences: byAttention, host: .local)
        #expect(visible.map(\.name) == ["work"])
        #expect(LeoSidebarLayout.orderedRows(rows, preferences: byAttention).map(\.name) == ["work", "idle"])
    }

    @Test func sectionIDOfARowFollowsTheMode() {
        let asking = row("a", attention: .needsInput)
        #expect(LeoSidebarLayout.sectionID(of: asking, preferences: byStatus) == LeoSidebarLayout.needsYouSectionID)
        #expect(LeoSidebarLayout.sectionID(of: row("b"), preferences: byStatus) == "running")
        #expect(LeoSidebarLayout.sectionID(of: row("b"), preferences: byAttention) == LeoSidebarLayout.idleStoppedSectionID)
        let pinned = LeoSidebarPreferences(pinned: [id("b")])
        #expect(LeoSidebarLayout.sectionID(of: row("b"), preferences: pinned) == LeoSidebarLayout.pinnedSectionID)
    }

    @Test func revealExpandsIdleAndStoppedInAttentionMode() {
        let model = makeModel([row("idle")], prefs: byAttention)
        #expect(model.sections[0].isCollapsed)
        model.reveal(id("idle"))
        #expect(!model.sections[0].isCollapsed)
    }

    // MARK: Filtering

    @Test func filteringFlattensBothModesIntoStatusGroupsWithoutNeedsYou() {
        let rows = [row("alpha", attention: .needsInput), row("alps", attention: .working), row("zed")]
        for prefs in [byStatus, byAttention] {
            let sections = LeoSidebarLayout.sections(rows: rows, query: "al", preferences: prefs, host: .local)
            #expect(sections.map(\.title) == ["Running"])
            #expect(sections.allSatisfy { !$0.isCollapsed && $0.isCollapsible && !$0.showsCount })
            #expect(Set(sections[0].rows.map(\.name)) == ["alpha", "alps"])
        }
    }

    // MARK: Preferences

    @Test func groupByRoundTripsAndDefaultsToStatus() throws {
        #expect(LeoSidebarPreferences().groupBy == .status)
        let prefs = LeoSidebarPreferences(sortOrder: .name, groupBy: .attention, pinned: [id("a")], collapsed: [.local: ["working"]])
        let data = try #require(prefs.encoded())
        #expect(LeoSidebarPreferences.decode(data) == prefs)
        let expanded = byAttention.setting(LeoSidebarLayout.idleStoppedSectionID, collapsed: false, host: .local)
        let expandedData = try #require(expanded.encoded())
        #expect(LeoSidebarPreferences.decode(expandedData) == expanded)
    }

    @Test func anOldBlobWithoutGroupByStillDecodes() {
        let old = Data(#"{"sortOrder":"name","pinned":[],"collapsed":{}}"#.utf8)
        let decoded = LeoSidebarPreferences.decode(old)
        #expect(decoded.sortOrder == .name)
        #expect(decoded.groupBy == .status)
    }

    @Test func anUnreadableGroupByFallsBackWithoutDroppingTheRest() {
        let blob = Data(#"{"sortOrder":"name","groupBy":"bogus"}"#.utf8)
        let decoded = LeoSidebarPreferences.decode(blob)
        #expect(decoded.sortOrder == .name)
        #expect(decoded.groupBy == .status)
    }

    @Test func settingGroupByPersistsThroughTheStoreAndKeepsTheOtherFields() {
        let store = LeoInMemorySidebarPreferencesStore(LeoSidebarPreferences(sortOrder: .name, pinned: [id("a")]))
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: [], connectivity: .connected, generation: 1), preferencesStore: store)
        model.setGroupBy(.attention)
        #expect(store.load().groupBy == .attention)
        #expect(store.load().sortOrder == .name)
        #expect(store.load().pinned == [id("a")])
    }

    // MARK: Helpers

    private func layout(_ rows: [LeoAgentRow], _ prefs: LeoSidebarPreferences) -> [LeoSidebarSection] {
        LeoSidebarLayout.sections(rows: rows, query: "", preferences: prefs, host: .local)
    }

    private func makeModel(_ rows: [LeoAgentRow], prefs: LeoSidebarPreferences) -> LeoSidebarModel {
        LeoSidebarModel(
            snapshot: LeoSidebarSnapshot(rows: rows, connectivity: .connected, generation: 1),
            preferencesStore: LeoInMemorySidebarPreferencesStore(prefs)
        )
    }

    private func id(_ name: String) -> LeoAgentRow.ID { LeoAgentRow.ID(host: .local, name: name) }

    private func row(
        _ name: String, status: LeoAgentStatus = .running, activity: LeoAgentRow.Activity = .idle,
        attention: LeoAttentionBadge? = nil, compaction: LeoRowCompaction? = nil
    ) -> LeoAgentRow {
        LeoAgentRow(
            host: .local, name: name, template: nil, status: status, activity: activity, actionDetail: nil,
            attention: attention, compaction: compaction
        )
    }
}
