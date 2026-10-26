import AppKit
import ImageIO
import Testing
import WebKit

@testable import Ghostty
@testable import LeoKit

/// C3: the WebKit page adapter in a real `WKWebView`, over in-memory
/// fixtures. The view sits in an off-screen window, as a parked tab does.
@MainActor
@Suite(.serialized, .enabled(if: LeoWKTestHost.hasWindowServer, "needs a window-server session"))
struct LeoWKBrowserPageTests {
    private static let form = """
    <title>Form</title>
    <h1>Sign in</h1>
    <form action="done">
      <label>Email <input id="email" value="ann@example.com"></label>
      <input type="checkbox" aria-label="Remember me" checked>
      <button>Go</button>
    </form>
    <a href="/next">Next page</a>
    <div style="display:none"><button>Hidden</button></div>
    """

    private static let pages = [
        "form": form,
        "other": "<title>Other</title><p>Elsewhere</p>",
        "long": (0..<3_000).map { "<p>Paragraph \($0) with some filler text in it</p>" }.joined(),
        "tall": #"<body style="margin:0"><div style="height:3000px;background:#3366cc"></div></body>"#,
        "console": """
        <script>
        console.log('hello', {a: 1});
        console.error('bad');
        Promise.reject(new Error('nope'));
        </script>
        """,
        "later": "<script>setTimeout(() => document.body.append('Ready now'), 50)</script>",
    ]

    @available(macOS 14, *)
    @Test func navigateReturnsTheFinalURLAndTitle() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        let location = try await page.navigate(to: LeoWKFixtureServer.url("form"))

        #expect(location == .init(url: LeoWKFixtureServer.url("form"), title: "Form"))
        #expect(await page.failureCode { try await $0.navigate(to: URL(string: "file:///etc/hosts")!) } == "scheme_not_allowed")
    }

    @available(macOS 14, *)
    @Test func snapshotListsRolesNamesValuesAndRefs() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("form"))

        let snapshot = try await page.snapshot()

        #expect(snapshot.contains(#"- heading "Sign in" [level=1]"#))
        #expect(snapshot.contains(#"textbox "Email" [ref=s"#))
        #expect(snapshot.contains(#": "ann@example.com""#))
        #expect(snapshot.contains(#"checkbox "Remember me" [ref=s"#))
        #expect(snapshot.contains("[checked]"))
        #expect(leoSnapshotRef(snapshot, #"button "Go""#) != nil)
        #expect(leoSnapshotRef(snapshot, #"link "Next page""#) != nil)
        #expect(!snapshot.contains("Hidden"))
    }

    @available(macOS 14, *)
    @Test func snapshotLeavesThePageDOMUntouched() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("form"))
        let before = try await page.eval("return document.documentElement.outerHTML")

        _ = try await page.snapshot()

        #expect(try await page.eval("return document.documentElement.outerHTML") == before)
    }

    @available(macOS 14, *)
    @Test func snapshotTruncatesAtTheLimitWithANote() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("long"))

        let snapshot = try await page.snapshot()

        let note = try #require(snapshot.range(of: "\n[snapshot truncated at 50000 characters"))
        #expect(snapshot[..<note.lowerBound].count <= 50_000)
        #expect(snapshot[..<note.lowerBound].count > 49_000)
    }

    @available(macOS 14, *)
    @Test func refGoesStaleAfterAnotherSnapshotOrANavigation() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("form"))
        let first = try #require(leoSnapshotRef(try await page.snapshot(), #"button "Go""#))
        _ = try await page.locate(ref: first)

        let second = try #require(leoSnapshotRef(try await page.snapshot(), #"button "Go""#))

        #expect(await page.failureCode { try await $0.locate(ref: first) } == "stale_ref")
        _ = try await page.locate(ref: second)
        _ = try await page.navigate(to: LeoWKFixtureServer.url("other"))
        #expect(await page.failureCode { try await $0.locate(ref: second) } == "stale_ref")
    }

    @available(macOS 14, *)
    @Test func evalReturnsTheResultAsJSON() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("form"))

        #expect(try await page.eval("return {title: document.title, n: 2}") == #"{"title":"Form","n":2}"#)
        #expect(try await page.eval("document.title") == "null")
    }

    @available(macOS 14, *)
    @Test func evalOfAThrownErrorIsAJSError() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("form"))

        #expect(await page.failureCode { try await $0.eval("throw new Error('boom')") } == "js_error")
    }

    @available(macOS 14, *)
    @Test func consoleCapturesLogsErrorsAndUnhandledRejections() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("console"))
        var entries: [LeoWKBrowserPage.ConsoleEntry] = []
        for _ in 0..<50 where entries.count < 3 {
            _ = try await page.eval("return 0")
            entries += page.console()
        }

        #expect(entries.map(\.level) == ["log", "error", "error"])
        #expect(entries.first?.text == #"hello {"a":1}"#)
        #expect(entries.last?.text.contains("nope") == true)
        #expect(page.console().isEmpty)
        #expect(page.console(since: 0).count == 3)
    }

    @available(macOS 14, *)
    @Test func fullPageScreenshotIsTallerThanTheViewportAndAtMost1600PixelsWide() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        fixture.window.setContentSize(CGSize(width: 2_000, height: 600))
        _ = try await page.navigate(to: LeoWKFixtureServer.url("tall"))

        let png = try await page.screenshot(fullPage: true)

        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        #expect(image.width <= 1_600)
        #expect(Double(image.height) / Double(image.width) > 600.0 / 2_000.0 * 4)
    }

    @available(macOS 14, *)
    @Test func waitForTextReturnsOnceThePageShowsIt() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("later"))

        try await page.wait(for: "Ready now", ms: 5_000)

        #expect(await page.failureCode { try await $0.wait(for: "Never shown", ms: 200) } == "timeout")
    }
}
