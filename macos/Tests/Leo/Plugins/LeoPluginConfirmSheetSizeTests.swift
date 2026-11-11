import AppKit
import Combine
import Foundation
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// A plugin can propose an arbitrarily long message or prompt (a CI log
/// excerpt is 150 lines). The sheet must stay on screen with its buttons
/// reachable, so the text area scrolls instead of growing the window. Found
/// live: a Send Failure sheet measured 460 x 2459 on a 1050-point screen.
/// Measured through the real presenter, after the sheet is attached: a window
/// that hasn't been shown yet reports a 32-point frame whatever its content.
@MainActor
struct LeoPluginConfirmSheetSizeTests {
    private static let longText = (1...400).map { "line \($0): some log output that fills the preview" }.joined(separator: "\n")
    private static let maxSheetHeight: CGFloat = 700

    /// The height of the sheet the presenter attaches to a parent window, once it has laid out.
    private func presentedHeight<Value>(
        _ content: @escaping (@escaping (Value?) -> Void) -> some View
    ) async -> CGFloat? {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        parent.makeKeyAndOrderFront(nil)
        defer { parent.close() }
        let presenter = LeoPluginSheetPresenter(hostWindow: { parent })
        let presenting = Task { await presenter.presentCancellable(content) }
        for _ in 0..<200 where parent.attachedSheet == nil {
            await Task.yield() // the presenting task shares the main actor: let it run
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let height = parent.attachedSheet?.frame.height
        presenting.cancel()
        _ = await presenting.value
        return height
    }

    @Test func aLongMessageDoesNotGrowTheSendSheetPastTheScreen() async throws {
        let draft = LeoPluginSendDraft(pluginName: "Demo", agent: LeoPluginAgentRef(machine: "localhost", name: "a"), text: Self.longText)
        let height = try #require(await presentedHeight { (finish: @escaping (String?) -> Void) in LeoPluginSendSheet(draft: draft, finish: finish) })
        #expect(height <= Self.maxSheetHeight)
    }

    @Test func aLongPromptDoesNotGrowTheSpawnSheetPastTheScreen() async throws {
        let spec = LeoPluginSpawnSpec(repo: "o/r", branch: "issue-2-x", base: nil, prompt: Self.longText, machine: "localhost", template: nil)
        let draft = LeoPluginSpawnDraft(pluginName: "Demo", spec: spec, machines: ["localhost"])
        let feed = LeoPluginSpawnTemplateFeed(
            list: { _ in Just(LeoTemplateListState.loaded([LeoTemplate(name: "implementer")])).eraseToAnyPublisher() },
            reload: { _ in })
        let height = try #require(await presentedHeight { (finish: @escaping (LeoPluginSpawnSpec?) -> Void) in
            LeoPluginSpawnSheet(draft: draft, templates: feed, finish: finish)
        })
        #expect(height <= Self.maxSheetHeight)
    }
}
