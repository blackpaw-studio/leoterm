import Foundation
import Testing

import LeoKit
@testable import Ghostty

@MainActor
struct LeoPluginSidebarSectionStateTests {
    private final class Prefs { var value = LeoSidebarPreferences() }

    private let issues = LeoPluginSidebarSectionContribution(id: "issues", title: "Issues")
    private let builds = LeoPluginSidebarSectionContribution(id: "builds", title: "Builds")

    private func make(_ plugins: [LeoPluginInfo]) -> (LeoPluginSidebarSections, LeoPluginSlotHostFake, Prefs) {
        let host = LeoPluginSlotHostFake(plugins: plugins)
        let prefs = Prefs()
        let sections = LeoPluginSidebarSections(host: host, preferences: { prefs.value }, update: { prefs.value = $0 })
        return (sections, host, prefs)
    }

    @Test func sectionsStartCollapsedAndSendNothing() throws {
        let (sections, host, _) = make([LeoPluginTestPlugins.info(sections: [issues, builds])])
        #expect(sections.entries.map(\.title) == ["Issues", "Builds"])
        #expect(sections.entries.allSatisfy { !sections.isExpanded($0) })
        #expect(host.opened.isEmpty)
    }

    @Test func firstExpandSendsActivateForThatSlotOnly() throws {
        let (sections, host, _) = make([LeoPluginTestPlugins.info(sections: [issues, builds])])
        sections.toggle(sections.entries[0])
        #expect(sections.isExpanded(sections.entries[0]))
        #expect(host.opened == [LeoPluginSlotKey(pluginID: "studio.test.demo", slot: .section(id: "issues"))])
    }

    @Test func collapsingAndReopeningWhileStillLoadingDoesNotResend() throws {
        let (sections, host, _) = make([LeoPluginTestPlugins.info(sections: [issues])])
        let entry = sections.entries[0]
        sections.toggle(entry)
        sections.toggle(entry)
        sections.toggle(entry)
        #expect(host.opened.count == 1)
    }

    @Test func expandingASectionThatAlreadyHasATreeSendsNothing() throws {
        let (sections, host, _) = make([LeoPluginTestPlugins.info(sections: [issues])])
        host.slots.render(
            pluginID: "studio.test.demo", slot: .section(id: "issues"),
            root: try LeoPluginSlotRoot(nodes: [.loading(.init(message: nil))]))
        sections.toggle(sections.entries[0])
        #expect(host.opened.isEmpty)
    }

    @Test func aSectionExpandedInAPreviousRunIsRequestedOnAppear() throws {
        let (sections, host, prefs) = make([LeoPluginTestPlugins.info(sections: [issues])])
        prefs.value = prefs.value.setting(pluginSection: sections.entries[0].id, collapsed: false)
        sections.ensureLoaded(sections.entries[0])
        sections.ensureLoaded(sections.entries[0])
        #expect(host.opened.count == 1)
    }

    @Test func expandStateRoundTripsThroughPreferencesEncoding() throws {
        let (sections, _, prefs) = make([LeoPluginTestPlugins.info(sections: [issues, builds])])
        sections.toggle(sections.entries[1])
        let restored = LeoSidebarPreferences.decode(prefs.value.encoded())
        let (again, _, _) = make([LeoPluginTestPlugins.info(sections: [issues, builds])])
        let reader = LeoPluginSidebarSections(host: again.host, preferences: { restored }, update: { _ in })
        #expect(reader.entries.map { reader.isExpanded($0) } == [false, true])
    }

    @Test func preferencesWrittenBeforePluginsExistedDecodeAsCollapsed() {
        let legacy = Data(#"{"sortOrder":"name"}"#.utf8)
        let prefs = LeoSidebarPreferences.decode(legacy)
        #expect(prefs.sortOrder == .name)
        #expect(prefs.expandedPluginSections.isEmpty)
    }

    @Test func hidingRemovesTheSectionAndSettingsCanBringItBack() throws {
        let (sections, host, _) = make([LeoPluginTestPlugins.info(sections: [issues, builds])])
        sections.hide(sections.entries[0])
        #expect(sections.entries.map(\.title) == ["Builds"])
        try host.setSection("studio.test.demo", section: "issues", hidden: false)
        #expect(sections.entries.map(\.title) == ["Issues", "Builds"])
    }

    @Test func sectionsOfOffPluginsAndManifestlessRecordsAreNotListed() {
        let off = LeoPluginTestPlugins.info(id: "a.off", enabled: false, sections: [issues])
        let on = LeoPluginTestPlugins.info(id: "b.on", name: "On", sections: [builds])
        let (sections, _, _) = make([off, on])
        #expect(sections.entries.map(\.pluginID) == ["b.on"])
    }

    @Test func aCrashedPluginKeepsItsSectionSoTheSlotCanShowTheNotice() {
        let (sections, _, _) = make([LeoPluginTestPlugins.info(state: .disabled(reason: "crashed"), sections: [issues])])
        #expect(sections.entries.count == 1)
    }

    @Test func sectionIdentityChangesWithOpenStateSoTheListRebuildsIt() throws {
        let (sections, _, _) = make([LeoPluginTestPlugins.info(sections: [issues, builds])])
        let entry = sections.entries[0]
        let closed = LeoPluginSectionIdentity.make(entry: entry, expanded: false)
        let open = LeoPluginSectionIdentity.make(entry: entry, expanded: true)
        #expect(closed != open)
        #expect(closed == LeoPluginSectionIdentity.make(entry: entry, expanded: false))
        #expect(open != LeoPluginSectionIdentity.make(entry: sections.entries[1], expanded: true))
    }
}
