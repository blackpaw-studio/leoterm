import AppKit
import Testing
import WebKit

@testable import Ghostty

/// B-407: the page-side finder in a real `WKWebView`, over in-memory fixtures.
@MainActor
@Suite(.serialized)
struct LeoBrowserFindScriptTests {
    private static let pages = [
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
}
