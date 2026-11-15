import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

struct LeoProgressWatchingTests {
    private static let alpha = LeoAgentRow.ID(host: .local, name: "alpha")
    private static let beta = LeoAgentRow.ID(host: .local, name: "beta")

    @Test func watchingNeedsTheActiveAppAndTheAgentSelectedWithNoTerminalTab() {
        #expect(LeoProgressWatching.isWatching(Self.alpha, isAppActive: true, showsTerminalTab: false, selected: Self.alpha))
    }

    @Test func aTerminalTabCoveringTheAgentIsNotWatching() {
        #expect(!LeoProgressWatching.isWatching(Self.alpha, isAppActive: true, showsTerminalTab: true, selected: Self.alpha))
    }

    @Test func anInactiveAppOrAnotherSelectionIsNotWatching() {
        #expect(!LeoProgressWatching.isWatching(Self.alpha, isAppActive: false, showsTerminalTab: false, selected: Self.alpha))
        #expect(!LeoProgressWatching.isWatching(Self.alpha, isAppActive: true, showsTerminalTab: false, selected: Self.beta))
        #expect(!LeoProgressWatching.isWatching(Self.alpha, isAppActive: true, showsTerminalTab: false, selected: nil))
    }
}
