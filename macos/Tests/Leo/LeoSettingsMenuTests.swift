import AppKit
import Carbon.HIToolbox
import Testing

@testable import Ghostty

/// B-397: App menu ▸ Settings… (⌘,) opens the Leo settings window. The
/// Ghostty config file action moved to its own item, Open Ghostty Config.
struct LeoSettingsMenuTests {
    @Test func settingsItemOpensLeoSettingsOnCommandComma() throws {
        #expect(try LeoMenuXib.titles(forAction: "showLeoSettings:") == ["Settings…"])

        let items = try LeoMenuXib.shortcuts()
        #expect(items.first { $0.action == "showLeoSettings:" }?.shortcut == "⌘,")
        #expect(
            try LeoMenuXib.intruders(onCommand: ",", ownedBy: "showLeoSettings:", in: items).map(\.title) == [],
            "only Settings… holds ⌘,"
        )
    }

    @Test func ghosttyConfigFileHasItsOwnItemWithNoShortcut() throws {
        #expect(try LeoMenuXib.titles(forAction: "openConfig:") == ["Open Ghostty Config"])
        #expect(try LeoMenuXib.shortcuts().contains { $0.action == "openConfig:" } == false)
    }
}

@MainActor struct LeoSettingsMenuIconTests {
    private func symbolImage(_ name: String) throws -> NSImage {
        try #require(NSImage(systemSymbolName: name, accessibilityDescription: nil))
    }

    @Test func theGearSitsOnSettingsAndNotOnOpenGhosttyConfig() throws {
        guard #available(macOS 26, *) else { return }  // icons are only set on macOS 26+
        let settings = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ",")
        let openConfig = NSMenuItem(title: "Open Ghostty Config", action: nil, keyEquivalent: "")

        LeoSettingsMenuIcons.apply(settings: settings, openConfig: openConfig)

        let gear = try symbolImage("gear")
        let settingsImage = try #require(settings.image)
        #expect(settingsImage.tiffRepresentation == gear.tiffRepresentation)
        #expect(openConfig.image?.tiffRepresentation != gear.tiffRepresentation)
    }
}

private final class Recorder: NSObject {
    var fired: [String] = []
    @objc func settings(_ sender: Any?) { fired.append("settings") }
    @objc func openConfig(_ sender: Any?) { fired.append("openConfig") }
}

@MainActor struct LeoSettingsMenuDispatchTests {
    private func commandComma() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: ",", charactersIgnoringModifiers: ",", isARepeat: false,
            keyCode: UInt16(kVK_ANSI_Comma)
        ))
    }

    @Test func aCommandCommaKeybindInATerminalOpensSettingsNotTheGhosttyConfig() throws {
        let recorder = Recorder()
        let settings = NSMenuItem(title: "Settings…", action: #selector(Recorder.settings(_:)), keyEquivalent: ",")
        let openConfig = NSMenuItem(title: "Open Ghostty Config", action: #selector(Recorder.openConfig(_:)), keyEquivalent: "")
        settings.target = recorder
        openConfig.target = recorder
        let menu = NSMenu(title: "Leo")
        menu.autoenablesItems = false
        menu.addItem(settings)
        menu.addItem(openConfig)

        let manager = Ghostty.MenuShortcutManager()
        manager.reset()
        LeoSettingsMenuShortcut.sync(settings: settings, manager: manager)

        #expect(manager.performGhosttyBindingMenuKeyEquivalent(with: try commandComma()))
        #expect(recorder.fired == ["settings"])
    }
}
