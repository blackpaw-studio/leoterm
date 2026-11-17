import AppKit
import Testing
import WebKit

@testable import Ghostty

/// B-407: the page-side finder in a real `WKWebView`, over in-memory fixtures.
@MainActor
@Suite(.serialized)
struct LeoBrowserFindScriptTests {
    /// A tall <pre> with its one match far down.
    private static let deepPage: String = {
        let before = (0..<3_000).map { "line \($0)" }.joined(separator: "\n")
        let after = (0..<200).map { "tail \($0)" }.joined(separator: "\n")
        return "<style>pre { font: 14px/20px monospace; margin: 0 }</style><pre>\(before)\ndeepneedle here\n\(after)</pre>"
    }()

    private static let pages: [String: String] = [
        "apples": "<p>Apple ap<b>ple</b> APPLE</p>",
        "blocks": "<p>foo</p><p>bar</p><p>foo bar</p>",
        "hidden": """
        <style>.gone { display: none } .invisible { visibility: hidden }</style>
        <p>needle one</p>
        <p class="gone">needle two</p>
        <p class="invisible">needle three</p>
        <script>var s = 'needle four'</script>
        <noscript>needle five</noscript>
        <p>needle six</p>
        """,
        "many": (0..<1_200).map { _ in "<i>x</i>" }.joined(),
        "tall": (0..<200).map { "<p>row \($0)</p>" }.joined() + "<p id=\"end\">findme</p>",
        "spacing": "<p>foo\n   bar</p><p>foo&nbsp;bar</p><p>foo      bar</p><p>x<br>y</p><p>a<br>b <b>c</b></p>",
        "wrapped": "<p id=\"p\">before  foo\n\t bar after</p>",
        "deep": deepPage,
        "restyle": "<p>Alpha apple and another apple, then Apple again.</p><p>foo bar baz</p><p>second foo bar here</p>",
        "selectable": "<p id=\"p\">Pick this phrase please</p>",
    ]

    private static func fixture() -> LeoWKPageFixture { LeoWKPageFixture(pages) }

    private func open(_ name: String, in fixture: LeoWKPageFixture) async throws -> LeoWKPageFinder {
        _ = try await fixture.page.navigate(to: LeoWKFixtureServer.url(name))
        return LeoWKPageFinder()
    }

    private func highlightCounts(_ fixture: LeoWKPageFixture) async throws -> (all: Int, current: Int) {
        let reply = try await fixture.page.webView.callAsyncJavaScript(
            """
            return [CSS.highlights.has('leo-find') ? CSS.highlights.get('leo-find').size : 0,
                    CSS.highlights.has('leo-find-current') ? CSS.highlights.get('leo-find-current').size : 0]
            """, arguments: [:], in: nil, contentWorld: LeoWKPageFinder.world) as? [Int]
        return (reply?[0] ?? -1, reply?[1] ?? -1)
    }

    @available(macOS 14, *)
    @Test func countsMatchesCaseInsensitivelyAcrossNodes() async throws {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("apples", in: fixture)

        let result = await finder.search("apple", in: fixture.page.webView)

        #expect(result == LeoFindResult(index: 1, total: 3, isCapped: false))
    }

    @available(macOS 14, *)
    @Test func stepsAndWraps() async throws {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("apples", in: fixture)
        let view = fixture.page.webView
        _ = await finder.search("apple", in: view)

        var indexes: [Int] = []
        for _ in 0..<3 { indexes.append(await finder.step(.next, query: "apple", in: view).index) }
        let previous = await finder.step(.previous, query: "apple", in: view)

        #expect(indexes == [2, 3, 1])
        #expect(previous.index == 3)
    }

    @available(macOS 14, *)
    @Test func aMatchNeverSpansBlocks() async throws {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("blocks", in: fixture)

        #expect(await finder.search("foobar", in: fixture.page.webView).total == 0)
        #expect(await finder.search("foo bar", in: fixture.page.webView).total == 1)
    }

    @available(macOS 14, *)
    @Test func skipsHiddenText() async throws {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("hidden", in: fixture)

        #expect(await finder.search("needle", in: fixture.page.webView).total == 2)
    }

    @available(macOS 14, *)
    @Test func emptyOrMissingQueryClears() async throws {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("apples", in: fixture)
        let view = fixture.page.webView
        _ = await finder.search("apple", in: view)

        #expect(await finder.search("zzz", in: view) == .none)
        #expect(try await highlightCounts(fixture) == (0, 0))
        _ = await finder.search("apple", in: view)
        #expect(await finder.search("", in: view) == .none)
        #expect(try await highlightCounts(fixture) == (0, 0))
    }

    @available(macOS 14, *)
    @Test func clearRemovesHighlightsAndTheStyleSheet() async throws {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("apples", in: fixture)
        let view = fixture.page.webView
        _ = await finder.search("apple", in: view)

        await finder.clear(in: view)

        #expect(try await highlightCounts(fixture) == (0, 0))
        #expect(try await fixture.page.eval("return document.adoptedStyleSheets.length") == "0")
    }

    @available(macOS 14, *)
    @Test func capsAtTheLimit() async throws {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("many", in: fixture)

        let result = await finder.search("x", in: fixture.page.webView)

        #expect(result == LeoFindResult(index: 1, total: LeoBrowserFindScript.matchLimit, isCapped: true))
    }

    @available(macOS 14, *)
    @Test func highlightsEveryMatchAndTheCurrentOne() async throws {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("apples", in: fixture)

        _ = await finder.search("apple", in: fixture.page.webView)

        #expect(try await highlightCounts(fixture) == (3, 1))
    }

    @available(macOS 14, *)
    @Test func leavesThePageDOMUntouched() async throws {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("apples", in: fixture)
        let before = try await fixture.page.eval("return document.documentElement.outerHTML")

        _ = await finder.search("apple", in: fixture.page.webView)

        #expect(try await fixture.page.eval("return document.documentElement.outerHTML") == before)
    }

    @available(macOS 14, *)
    @Test func scrollsTheCurrentMatchIntoView() async throws {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("tall", in: fixture)

        _ = await finder.search("findme", in: fixture.page.webView)

        #expect(try await fixture.page.eval("return window.scrollY") != "0")
    }

    @available(macOS 14, *)
    @Test func selectedTextIsThePageSelection() async throws {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("selectable", in: fixture)
        let view = fixture.page.webView
        #expect(await finder.selectedText(in: view) == nil)
        _ = try await fixture.page.eval(
            "const r = document.createRange(); r.selectNodeContents(document.getElementById('p').firstChild); getSelection().removeAllRanges(); getSelection().addRange(r); return 1")

        #expect(await finder.selectedText(in: view) == "Pick this phrase please")
    }

    @Test func aViewThatIsNotAPageFindsNothing() async {
        let finder = LeoWKPageFinder()

        #expect(await finder.search("a", in: NSView()) == .none)
        #expect(await finder.search("a", in: nil) == .none)
    }

    @available(macOS 14, *)
    @Test func whitespaceRunsNewlinesAndNoBreakSpacesMatchOneSpace() async throws {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("spacing", in: fixture)

        #expect(await finder.search("foo bar", in: fixture.page.webView).total == 3)
        #expect(await finder.search("foo   bar", in: fixture.page.webView).total == 3)
    }

    @available(macOS 14, *)
    @Test func aLineBreakSeparatesWordsButASpaceAfterItStillMatches() async throws {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("spacing", in: fixture)
        let view = fixture.page.webView

        #expect(await finder.search("xy", in: view).total == 0)
        #expect(await finder.search("ab", in: view).total == 0)
        #expect(await finder.search("b c", in: view).total == 1)
    }

    @available(macOS 14, *)
    @Test func aMatchAcrossCollapsedWhitespaceHighlightsTheRealText() async throws {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("wrapped", in: fixture)

        let result = await finder.search("FOO bar", in: fixture.page.webView)
        let text = try await fixture.page.webView.callAsyncJavaScript(
            "return [...CSS.highlights.get('leo-find-current')].map(String).join('|')",
            arguments: [:], in: nil, contentWorld: LeoWKPageFinder.world) as? String

        #expect(result.total == 1)
        #expect(text == "foo\n\t bar")
    }

    @available(macOS 14, *)
    @Test func scrollsAMatchDeepInsideATallElementIntoView() async throws {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("deep", in: fixture)

        let result = await finder.search("deepneedle", in: fixture.page.webView)
        let isVisible = try await fixture.page.webView.callAsyncJavaScript(
            """
            const rect = [...CSS.highlights.get('leo-find-current')][0].getBoundingClientRect();
            return rect.top >= 0 && rect.bottom <= innerHeight
            """, arguments: [:], in: nil, contentWorld: LeoWKPageFinder.world) as? Bool

        #expect(result.total == 1)
        #expect(isVisible == true)
    }

    /// Records every `Highlight` the finder registers, so a test can look at
    /// the ones it later replaced.
    private static let recordHighlights = """
    if (!globalThis.__leoSeen) {
      globalThis.__leoSeen = [];
      const set = CSS.highlights.set.bind(CSS.highlights);
      CSS.highlights.set = (name, highlight) => { globalThis.__leoSeen.push(highlight); return set(name, highlight); };
    }
    return 1
    """

    /// How many `Highlight`s the finder registered that are no longer
    /// registered but still hold ranges. WebKit repaints a range when its
    /// highlight lets go of it; a replaced highlight that keeps its ranges
    /// leaves their old marks painted (seen in the browser pane: the old
    /// query's matches stayed highlighted after the query changed).
    private func orphansHoldingRanges(_ fixture: LeoWKPageFixture) async throws -> Int? {
        try await fixture.page.webView.callAsyncJavaScript(
            """
            const live = new Set([...CSS.highlights.values()]);
            return globalThis.__leoSeen.filter((h) => !live.has(h) && h.size > 0).length
            """, arguments: [:], in: nil, contentWorld: LeoWKPageFinder.world) as? Int
    }

    private func searches(_ queries: [String]) async throws -> Int? {
        let fixture = Self.fixture()
        defer { fixture.close() }
        let finder = try await open("restyle", in: fixture)
        _ = try await fixture.page.webView.callAsyncJavaScript(
            Self.recordHighlights, arguments: [:], in: nil, contentWorld: LeoWKPageFinder.world)
        for query in queries { _ = await finder.search(query, in: fixture.page.webView) }
        return try await orphansHoldingRanges(fixture)
    }

    @available(macOS 14, *)
    @Test func aReplacedQueryLeavesNoHighlightHoldingTheOldMatches() async throws {
        #expect(try await searches(["apple", "foo bar"]) == 0)
    }

    @available(macOS 14, *)
    @Test func typingCharByCharThenChangingTheQueryLeavesNoHighlightHoldingOldMatches() async throws {
        let typed = ["a", "ap", "app", "appl", "apple", "f", "fo", "foo", "foo ", "foo b", "foo ba", "foo bar"]

        #expect(try await searches(typed) == 0)
    }
}
