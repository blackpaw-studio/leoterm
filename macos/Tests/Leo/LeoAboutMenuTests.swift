import AppKit
import Testing

@testable import Ghostty

/// B-130: the app menu's About item and the About window name Leo, not
/// Ghostty. Debug builds read "About Leo" too: the "[DEBUG]" suffix marks
/// the build in the menu bar, it isn't part of the product's name.
@MainActor struct LeoAboutMenuTests {
    /// Every main-menu item (submenus included) whose action is `selector`.
    private func menuItems(_ selector: Selector) -> [NSMenuItem] {
        func walk(_ menu: NSMenu?) -> [NSMenuItem] {
            (menu?.items ?? []).flatMap { [$0] + walk($0.submenu) }
        }
        return walk(NSApp.mainMenu).filter { $0.action == selector }
    }

    @Test func theXibAboutItemSaysAboutLeo() throws {
        #expect(try LeoMenuXib.titles(forAction: "showAbout:") == ["About Leo"])
    }

    @Test func theLiveAboutItemSaysAboutLeo() {
        #expect(menuItems(#selector(AppDelegate.showAbout(_:))).map(\.title) == ["About Leo"])
    }

    @Test func theAboutWindowNamesLeo() {
        #expect(AboutView.appName == "Leo")
    }
}
