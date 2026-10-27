import LeoFeatures
import LeoKit
import Testing
import UIKit

@testable import Leo

struct AgentPresentationTests {
    private func agent(_ appearance: LeoAgentAppearance?, activity: LeoActivity = .working) -> Agent {
        Agent(name: "zeus", status: .running, activity: activity, appearance: appearance)
    }

    @Test func anAgentWithNoAppearanceKeepsTodaysSymbolAndHasNoBar() {
        let style = agent(nil).rowStyle
        #expect(style.leading == .status(symbol: "circle.dotted.circle.fill", tint: .systemBlue))
        #expect(style.bar == nil)
    }

    @Test func anEmojiMakesATileWithTheStatusColorForItsDot() {
        let style = agent(LeoAgentAppearance(emoji: "🏛️", color: nil, emojiSource: .manual)).rowStyle
        #expect(style.leading == .tile(emoji: "🏛️", statusTint: .systemBlue))
        #expect(style.bar == nil)
    }

    @Test func aColorAloneKeepsTheSymbolAndAddsTheBar() {
        let style = agent(LeoAgentAppearance(emoji: nil, color: .teal, colorSource: .rule(0))).rowStyle
        #expect(style.leading == .status(symbol: "circle.dotted.circle.fill", tint: .systemBlue))
        #expect(style.bar == .teal)
    }

    @Test func bothGiveATileAndABar() {
        let style = agent(LeoAgentAppearance(emoji: "🎩", color: .pink, emojiSource: .rule(1), colorSource: .rule(1)), activity: .idle).rowStyle
        #expect(style.leading == .tile(emoji: "🎩", statusTint: .systemIndigo))
        #expect(style.bar == .pink)
    }

    @Test func everyPaletteColorHasItsOwnSystemColor() {
        #expect(Set(LeoAppearanceColor.allCases.map(\.uiColor)).count == LeoAppearanceColor.allCases.count)
    }
}
