import AppKit
import Testing

@testable import Ghostty

/// B-081: a start screen reads the title a new window loads with -- with a
/// config `title` set, that title. The controller runs on a `Ghostty.App`
/// loaded from a config file that sets only `title` (never the user's
/// config), as `LeoSidebarTitlebarStyleTests` does for the titlebar style.
/// The window is built but never shown; it has no surface.
@MainActor @Suite(.serialized)
struct LeoStartTitleTests {
    private static let configuredTitle = "Build box"

    @Test func theStartScreenReadsTheConfigsTitle() throws {
        let ghostty = try Self.app(title: Self.configuredTitle)
        let controller = TerminalController(ghostty, withSurfaceTree: .init(), leoIsPlaceholder: true)
        defer { controller.closeTabImmediately(registerRedo: false) }
        let window = try #require(controller.window)
        // As the window's last shell left it.
        window.title = "make test"

        controller.leoShowStartScreen()

        #expect(window.title == Self.configuredTitle)
    }

    /// A `Ghostty.App` whose config sets only `title`, from a temporary
    /// file.
    private static func app(title: String) throws -> Ghostty.App {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leo-b081-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        try "title = \(title)\n".write(to: file, atomically: true, encoding: .utf8)
        let app = Ghostty.App(configPath: file.path)
        try #require(app.readiness == .ready, "the Ghostty app didn't load its config")
        try #require(app.config.title == title, "the config didn't take")
        return app
    }
}
