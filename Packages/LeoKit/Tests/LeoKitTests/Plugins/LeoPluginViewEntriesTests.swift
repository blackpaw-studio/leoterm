import Foundation
import Testing

@testable import LeoKit

private func manifest(_ id: String, views: [LeoPluginViewContribution]) -> LeoPluginManifest {
    LeoPluginManifest(
        id: id, name: "Name \(id)", version: "1.0.0", apiVersion: 1, main: "main.js", permissions: .none,
        contributes: LeoPluginContributions(views: views))
}

private func info(
    _ id: String, views: [LeoPluginViewContribution], enabled: Bool = true, state: LeoPluginRunState = .running, hasManifest: Bool = true
) -> LeoPluginInfo {
    LeoPluginInfo(
        id: id, name: "Name \(id)", version: "1.0.0", source: .bundled, isEnabled: enabled, state: state, approvedPermissions: .none,
        manifest: hasManifest ? manifest(id, views: views) : nil, hiddenSections: [])
}

private let main = LeoPluginViewContribution(id: "main", title: "Main", sfSymbol: "star")
private let other = LeoPluginViewContribution(id: "other", title: "Other", sfSymbol: "moon")

@Suite struct LeoPluginViewEntriesTests {
    @Test func listsEachRunningPluginsViewsInManifestOrder() {
        let entries = LeoPluginViewEntries.make(from: [info("studio.a", views: [main, other])])
        #expect(entries.map(\.viewID) == ["main", "other"])
        #expect(entries[0].pluginName == "Name studio.a")
        #expect(entries[0].sfSymbol == "star")
        #expect(entries[0].title == "Main")
    }

    @Test func pluginsAreOrderedById() {
        let entries = LeoPluginViewEntries.make(from: [info("studio.z", views: [main]), info("studio.a", views: [main])])
        #expect(entries.map(\.pluginID) == ["studio.a", "studio.z"])
    }

    @Test func pluginsThatAreOffOrUnusableContributeNothing() {
        let plugins = [
            info("a", views: [main], enabled: false, state: .stoppedByUser),
            info("b", views: [main], state: .disabled(reason: "crashed")),
            info("c", views: [main], state: .refused("bad")),
            info("d", views: [main], state: .needsApproval(LeoPluginPermissionDiff(old: .none, new: LeoPluginPermissions(secrets: true)))),
            info("e", views: [main], hasManifest: false),
        ]
        #expect(LeoPluginViewEntries.make(from: plugins).isEmpty)
    }

    @Test func aRestartingPluginStillListsItsViews() {
        let entries = LeoPluginViewEntries.make(from: [info("a", views: [main], state: .restarting(reason: "crash"))])
        #expect(entries.map(\.viewID) == ["main"])
    }
}
