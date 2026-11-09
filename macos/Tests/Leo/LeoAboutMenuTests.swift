import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

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

/// B-366: the About window's buttons and links go to Leo's own repo, not
/// Ghostty's. There is no Leo docs site, so Docs opens the repo README.
@MainActor struct LeoAboutLinksTests {
    private static let repo = "https://github.com/blackpaw-studio/leoterm"

    @Test func githubButtonOpensTheLeoRepo() {
        #expect(AboutView.githubURL?.absoluteString == Self.repo)
    }

    @Test func docsButtonOpensTheLeoReadme() {
        #expect(AboutView.docsURL?.absoluteString == "\(Self.repo)#readme")
    }

    @Test func commitLinkOpensTheLeoCommit() {
        #expect(AboutView.commitURL(commit: "abc1234")?.absoluteString == "\(Self.repo)/commits/abc1234")
    }

    @Test func versionLinkOpensTheLeoReleaseTag() {
        #expect(AboutView.releaseNotesURL(version: "0.49.0")?.absoluteString == "\(Self.repo)/releases/tag/leo-v0.49.0")
    }
}
