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
@MainActor
struct LeoPluginConfirmSheetSizeTests {
    private static let longText = (1...400).map { "line \($0): some log output that fills the preview" }.joined(separator: "\n")
    private static let maxSheetHeight: CGFloat = 700

    private func fittingHeight(of view: some View) -> CGFloat {
        NSHostingController(rootView: view).view.fittingSize.height
    }

    @Test func aLongMessageDoesNotGrowTheSendSheetPastTheScreen() {
        let draft = LeoPluginSendDraft(pluginName: "Demo", agent: LeoPluginAgentRef(machine: "localhost", name: "a"), text: Self.longText)
        let height = fittingHeight(of: LeoPluginSendSheet(draft: draft, finish: { _ in }))
        #expect(height <= Self.maxSheetHeight)
    }

    @Test func aLongPromptDoesNotGrowTheSpawnSheetPastTheScreen() {
        let spec = LeoPluginSpawnSpec(repo: "o/r", branch: "issue-2-x", base: nil, prompt: Self.longText, machine: "localhost", template: nil)
        let draft = LeoPluginSpawnDraft(pluginName: "Demo", spec: spec, machines: ["localhost"])
        let feed = LeoPluginSpawnTemplateFeed(
            list: { _ in Just(LeoTemplateListState.loaded([LeoTemplate(name: "implementer")])).eraseToAnyPublisher() },
            reload: { _ in })
        let height = fittingHeight(of: LeoPluginSpawnSheet(draft: draft, templates: feed, finish: { _ in }))
        #expect(height <= Self.maxSheetHeight)
    }
}
