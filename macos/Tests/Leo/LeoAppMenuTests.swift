import AppKit
import Testing

@testable import Ghostty

/// B-365: the app menu's items name Leo, not Ghostty. (The About window's
/// Ghostty links and the Help item's docs link are separate: B-366.)
@MainActor struct LeoAppMenuTests {
    private func liveTitles(_ selector: Selector) -> [String] {
        func walk(_ menu: NSMenu?) -> [NSMenuItem] {
            (menu?.items ?? []).flatMap { [$0] + walk($0.submenu) }
        }
        return walk(NSApp.mainMenu).filter { $0.action == selector }.map(\.title)
    }

    @Test func theXibAppMenuItemsSayLeo() throws {
        #expect(try LeoMenuXib.titles(forAction: "setAsDefaultTerminal:") == ["Make Leo the Default Terminal"])
        #expect(try LeoMenuXib.titles(forAction: "hide:") == ["Hide Leo"])
        #expect(try LeoMenuXib.titles(forAction: "terminate:") == ["Quit Leo"])
        #expect(try LeoMenuXib.titles(forAction: "showHelp:") == ["Leo Help"])
    }

    @Test func theLiveAppMenuItemsSayLeo() {
        #expect(liveTitles(#selector(AppDelegate.setAsDefaultTerminal(_:))) == ["Make Leo the Default Terminal"])
        #expect(liveTitles(#selector(NSApplication.hide(_:))) == ["Hide Leo"])
        #expect(liveTitles(#selector(NSApplication.terminate(_:))) == ["Quit Leo"])
        #expect(liveTitles(#selector(AppDelegate.showHelp(_:))) == ["Leo Help"])
    }
}
