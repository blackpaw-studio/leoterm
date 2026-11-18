import AppKit

/// B-400: the gear belongs on App menu ▸ Settings…, as in first-party Mac
/// apps. Open Ghostty Config (the config file action, B-397) carries a
/// document icon instead, so the two never share a glyph.
enum LeoSettingsMenuIcons {
    static func apply(settings: NSMenuItem?, openConfig: NSMenuItem?) {
        settings?.setImageIfDesired(systemSymbolName: "gear")
        openConfig?.setImageIfDesired(systemSymbolName: "doc.text")
    }
}
