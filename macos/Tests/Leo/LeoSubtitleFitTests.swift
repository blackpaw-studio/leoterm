import SwiftUI
import Testing

@testable import Ghostty

/// B-043 (D-076): the subtitle drops the template rather than squeeze it
/// below a few legible characters; the state and the time always stay.
struct LeoSubtitleFitTests {
    private typealias Subtitle = LeoAgentRowPresentation.Subtitle

    /// One point per character, so widths read as character counts.
    private let measure: (String) -> CGFloat = { CGFloat($0.count) }

    private func subtitle(template: String?, state: String? = "Needs Input", time: String? = "13h") -> Subtitle {
        Subtitle(
            template: template,
            state: state.map { LeoAgentRowPresentation.State(label: $0, tint: .orange) },
            lastActive: time
        )
    }

    @Test func aLineThatFitsIsUnchanged() {
        let full = subtitle(template: "claude") // "claude · Needs Input · 13h" = 26
        #expect(full.fitting(width: 26, measure: measure) == full)
    }

    @Test func aTemplateThatWouldShowFewerThanFiveCharactersDrops() {
        // At 25 the template could show only "clau…": drop it.
        let fitted = subtitle(template: "claude").fitting(width: 25, measure: measure)
        #expect(fitted.template == nil)
        #expect(fitted.segments.map(\.text) == ["Needs Input", "13h"])
        #expect(fitted.segments.map(\.hasSeparator) == [false, true])
    }

    @Test func aLongTemplateKeepsFiveCharactersBeforeItDrops() {
        let long = subtitle(template: "claude-opus") // whole = 31; "claud…" line = 26
        #expect(long.fitting(width: 26, measure: measure) == long, "truncates to claud…, still legible")
        #expect(long.fitting(width: 25, measure: measure).template == nil)
    }

    @Test func aShortTemplateShowsOnlyWhole() {
        let short = subtitle(template: "cc") // "cc · Needs Input · 13h" = 22
        #expect(short.fitting(width: 22, measure: measure) == short)
        #expect(short.fitting(width: 21, measure: measure).template == nil)
    }

    @Test func aNarrowTemplateThatFitsWholeStaysEvenWhenItsTruncationIsWider() {
        // "i" is half a point, so "iiiiii" (3) is narrower than "iiiii…" (3.5).
        let narrow: (String) -> CGFloat = { text in text.reduce(0) { $0 + ($1 == "i" ? 0.5 : 1) } }
        let line = subtitle(template: "iiiiii") // "iiiiii · Needs Input · 13h" = 3 + 3 + 17
        #expect(line.fitting(width: 23, measure: narrow) == line)
        #expect(line.fitting(width: 22.5, measure: narrow).template == nil)
    }

    @Test func theTemplateAloneNeverDrops() {
        let alone = subtitle(template: "claude-opus", state: nil, time: nil)
        #expect(alone.fitting(width: 3, measure: measure) == alone, "nothing else to show; it truncates")
    }

    @Test func noTemplateIsUnchanged() {
        let bare = subtitle(template: nil)
        #expect(bare.fitting(width: 1, measure: measure) == bare)
    }

    @Test func theFittedLineKeepsTheFullTextForTheTooltip() {
        let full = subtitle(template: "claude")
        #expect(full.text == "claude · Needs Input · 13h")
        #expect(full.fitting(width: 10, measure: measure).text == "Needs Input · 13h")
    }

    // MARK: B-259 usage

    private func usageSubtitle() -> Subtitle {
        Subtitle(template: "claude", state: nil, lastActive: "now", usage: "12.3k tok · $0.42 · 37% ctx")
    }

    @Test func usageIsWholeWhenTheLineFits() {
        // "claude · 12.3k tok · $0.42 · 37% ctx · now" = 42
        #expect(usageSubtitle().fitting(width: 42, measure: measure) == usageSubtitle())
    }

    @Test func usageDropsWholeComponentsFromTheRightNeverAPartialNumber() {
        #expect(usageSubtitle().fitting(width: 41, measure: measure).usage == "12.3k tok · $0.42")
        #expect(usageSubtitle().fitting(width: 32, measure: measure).usage == "12.3k tok · $0.42")
        #expect(usageSubtitle().fitting(width: 31, measure: measure).usage == "12.3k tok")
        #expect(usageSubtitle().fitting(width: 24, measure: measure).usage == "12.3k tok")
    }

    @Test func usageDropsEntirelyBeforeTheTemplateIsTouched() {
        let fitted = usageSubtitle().fitting(width: 23, measure: measure)
        #expect(fitted.usage == nil)
        #expect(fitted.template == "claude")
        #expect(fitted.segments.map(\.text) == ["claude", "now"])
    }

    @Test func aUsageOnlyLineKeepsItsFirstComponent() {
        let only = Subtitle(template: nil, state: nil, lastActive: nil, usage: "12.3k tok · $0.42")
        #expect(only.fitting(width: 3, measure: measure).usage == "12.3k tok")
    }

    @Test func droppedUsageKeepsItsHoverAndSpokenText() {
        var line = usageSubtitle()
        line.usageTooltip = "Session: 12,345 tokens"
        line.usageSpoken = "used 12,345 tokens"
        let fitted = line.fitting(width: 23, measure: measure)
        #expect(fitted.usage == nil)
        #expect(fitted.help.contains("Session: 12,345 tokens"))
        #expect(fitted.accessibilityLabel.contains("used 12,345 tokens"))
    }
}
