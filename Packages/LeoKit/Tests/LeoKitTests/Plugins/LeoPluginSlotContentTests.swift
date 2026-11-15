import Foundation
import Testing

@testable import LeoKit

private let loadingNode = LeoPluginNode.loading(.init(message: "x"))
private let emptyNode = LeoPluginNode.emptyState(.init(title: "t", message: nil, sfSymbol: nil, actions: []))

@Suite struct LeoPluginSlotContentTests {
    @Test func loadingShowsLoading() {
        #expect(LeoPluginSlotContent.resolve(state: .loading, pushed: [], pluginAvailable: true) == .loading)
    }

    @Test func aTreeShowsItsNodes() throws {
        let root = try LeoPluginSlotRoot(nodes: [loadingNode, emptyNode])
        #expect(
            LeoPluginSlotContent.resolve(state: .tree(root), pushed: [], pluginAvailable: true)
                == .nodes([loadingNode, emptyNode], isPushed: false))
    }

    @Test func aPushedViewReplacesTheRootAndCanGoBack() throws {
        let root = try LeoPluginSlotRoot(nodes: [loadingNode])
        let content = LeoPluginSlotContent.resolve(state: .tree(root), pushed: [emptyNode, loadingNode], pluginAvailable: true)
        #expect(content == .nodes([loadingNode], isPushed: true))
    }

    @Test func anErrorKeepsItsMessageForARetry() {
        #expect(LeoPluginSlotContent.resolve(state: .error("boom"), pushed: [], pluginAvailable: true) == .error("boom"))
    }

    @Test func aDisabledPluginShowsItsNotice() {
        #expect(LeoPluginSlotContent.resolve(state: .disabled("crashed 3 times"), pushed: [], pluginAvailable: true) == .notice("crashed 3 times"))
    }

    @Test func aPluginThatWentAwayShowsANoticeNotAnEndlessSpinner() {
        let content = LeoPluginSlotContent.resolve(state: .loading, pushed: [], pluginAvailable: false)
        #expect(content == .notice(LeoPluginSlotContent.unavailableNotice))
    }
}
