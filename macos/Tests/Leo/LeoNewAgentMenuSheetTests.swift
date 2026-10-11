import AppKit
import GhosttyKit
import Testing

@testable import Ghostty

/// B-284: Agents ▸ New Agent… must open the spawn sheet on a real terminal
/// window. `TerminalController` sets `window.contentView` directly and never
/// a `contentViewController`, so presenting through that property was a
/// silent no-op. Needs the app's real `Ghostty.App`.
@MainActor @Suite(.serialized) struct LeoNewAgentMenuSheetTests {
    @Test func newLeoAgentPresentsTheSpawnSheetOnATerminalWindow() throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty, "needs the app's Ghostty.App")
        let app = try #require(ghostty.app)
        let controller = TerminalController(ghostty, withSurfaceTree: SplitTree(view: Ghostty.SurfaceView(app, baseConfig: nil)))
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let registry = LeoWindowSessionRegistry()
        _ = registry.makeSession(window: window, controller: controller, defaults: LeoInMemoryDefaults())
        defer { controller.closeTabImmediately(registerRedo: false) }
        window.makeKeyAndOrderFront(nil)
        #expect(window.contentViewController == nil)

        controller.newLeoAgent(nil)

        let sheet = window.attachedSheet
        #expect(sheet != nil)
        if let sheet { window.endSheet(sheet) }
    }
}
