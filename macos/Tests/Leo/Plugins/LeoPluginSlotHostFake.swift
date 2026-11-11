import Foundation

import LeoKit
@testable import Ghostty

/// A plugin manager stand-in: records what the slots ask of it.
@MainActor final class LeoPluginSlotHostFake: LeoPluginSlotHosting {
    var plugins: [LeoPluginInfo]
    let slots = LeoPluginSlotStore()
    private(set) var opened: [LeoPluginSlotKey] = []
    private(set) var retried: [LeoPluginSlotKey] = []
    private(set) var performed: [(action: LeoPluginAction, plugin: String, slot: LeoPluginSlotID?)] = []

    init(plugins: [LeoPluginInfo] = []) { self.plugins = plugins }

    func open(_ slot: LeoPluginSlotID, plugin id: String) -> Bool {
        opened.append(LeoPluginSlotKey(pluginID: id, slot: slot))
        slots.expect(pluginID: id, slot: slot)
        return true
    }

    private(set) var visibility: [(plugin: String, visible: Bool)] = []
    func setSlotVisible(plugin id: String, visible: Bool) { visibility.append((id, visible)) }

    func retry(_ key: LeoPluginSlotKey) { retried.append(key) }

    func perform(_ action: LeoPluginAction, plugin id: String, slot: LeoPluginSlotID?, gesture: LeoPluginGesture?) {
        performed.append((action, id, slot))
    }

    /// What Settings → Plugins does to a section.
    func setSection(_ id: String, section: String, hidden: Bool) throws {
        plugins = plugins.map { info in
            guard info.id == id else { return info }
            let rest = info.hiddenSections.filter { $0 != section }
            return LeoPluginInfo(
                id: info.id, name: info.name, version: info.version, source: info.source, isEnabled: info.isEnabled, state: info.state,
                approvedPermissions: info.approvedPermissions, manifest: info.manifest, hiddenSections: hidden ? rest + [section] : rest)
        }
    }
}

enum LeoPluginTestPlugins {
    static func info(
        id: String = "studio.test.demo", name: String = "Demo", enabled: Bool = true, state: LeoPluginRunState = .running,
        sections: [LeoPluginSidebarSectionContribution] = [], commands: [LeoPluginCommandContribution] = [], hidden: [String] = []
    ) -> LeoPluginInfo {
        LeoPluginInfo(
            id: id, name: name, version: "1.0.0", source: .bundled, isEnabled: enabled, state: state, approvedPermissions: .none,
            manifest: LeoPluginManifest(
                id: id, name: name, version: "1.0.0", apiVersion: 1, main: "main.js",
                contributes: LeoPluginContributions(commands: commands, sidebarSections: sections)),
            hiddenSections: hidden)
    }
}
