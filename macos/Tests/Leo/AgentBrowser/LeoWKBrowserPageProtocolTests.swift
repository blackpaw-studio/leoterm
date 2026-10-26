import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// The WebKit page as LeoKit's `LeoBrowserPage`: what the executor drives.
/// Errors reach the agent with the page's own codes, chords become real
/// keys, and the console cursor continues where the last batch ended.
@MainActor
@Suite(.serialized, .enabled(if: LeoWKTestHost.hasWindowServer, "needs a window-server session"))
struct LeoWKBrowserPageProtocolTests {
    private static let pages = [
        "form": """
        <title>Form</title>
        <input id="field" aria-label="Name">
        <script>
        window.keys = [];
        document.getElementById('field').addEventListener('keydown', e => {
          keys.push([e.key, e.ctrlKey && 'ctrl', e.shiftKey && 'shift', e.altKey && 'alt', e.metaKey && 'meta'].filter(Boolean).join(' '));
        });
        </script>
        """,
        "console": "<script>console.log('one'); console.warn('two'); console.error('three')</script>",
    ]

    /// One tab over a real page, for driving the executor.
    @available(macOS 14, *)
    private final class OneTab: LeoBrowserTabs {
        let page: LeoWKBrowserPage

        init(_ page: LeoWKBrowserPage) { self.page = page }

        var tabs: [LeoBrowserTabInfo] { [LeoBrowserTabInfo(id: 1, url: page.url, title: page.title, isActive: true)] }
        func page(forTab id: Int?) -> (any LeoBrowserPage)? { id == nil || id == 1 ? page : nil }
        func openTab(url: URL) async throws -> Int { 1 }
        func selectTab(_ id: Int) {}
        func closeTab(_ id: Int) {}
    }

    @available(macOS 14, *)
    private func executor(_ page: LeoWKBrowserPage) -> LeoBrowserExecutor {
        LeoBrowserExecutor(tabs: OneTab(page), urlMapping: LeoIdentityURLMapping(), control: LeoBrowserControlModel())
    }

    @available(macOS 14, *)
    @Test func aLoadReportsTheURLAndTheDocumentsTitle() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page: any LeoBrowserPage = fixture.page

        try await page.load(LeoWKFixtureServer.url("form"))

        #expect(page.url == LeoWKFixtureServer.url("form"))
        #expect(page.title == "Form")
    }

    @available(macOS 14, *)
    @Test func aStaleRefReachesTheAgentAsStaleRef() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        try await fixture.page.load(LeoWKFixtureServer.url("form"))
        let executor = executor(fixture.page)
        let first = try #require(leoSnapshotRef(try await fixture.page.snapshot(), #"textbox "Name""#))
        _ = try await fixture.page.snapshot()

        let outcome = await executor.execute(tool: "browser_click", args: .object(["ref": .string(first)]), requestID: "ctr_1")

        #expect(outcome == .failure(LeoClientToolError(code: "stale_ref", message: LeoBrowserError.staleRef(first).message)))
    }

    @available(macOS 14, *)
    @Test func aChordIsPressedWithItsModifiers() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        try await fixture.page.load(LeoWKFixtureServer.url("form"))
        let executor = executor(fixture.page)
        let field = try #require(leoSnapshotRef(try await fixture.page.snapshot(), #"textbox "Name""#))
        #expect(await executor.execute(tool: "browser_click", args: .object(["ref": .string(field)]), requestID: "ctr_1") == .success([.text("ok")]))

        for key in ["Control+Shift+ArrowLeft", "Alt+x", "Enter"] {
            let outcome = await executor.execute(tool: "browser_press", args: .object(["key": .string(key)]), requestID: "ctr_2")
            #expect(outcome == .success([.text("ok")]), "\(key)")
        }

        #expect(try await fixture.page.eval("return keys") == #"["ArrowLeft ctrl shift","x alt","Enter"]"#)
    }

    @available(macOS 14, *)
    @Test func theConsoleCursorContinuesAfterTheLastBatch() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page: any LeoBrowserPage = fixture.page
        try await page.load(LeoWKFixtureServer.url("console"))
        _ = try await page.evaluate("return 0")

        let first = page.consoleMessages(since: nil)
        let none = page.consoleMessages(since: first.cursor)
        let again = page.consoleMessages(since: 1)

        #expect(first.entries.map(\.text) == ["one", "two", "three"])
        #expect(first.entries.map(\.level) == ["log", "warn", "error"])
        #expect(first.cursor == 3)
        #expect(none.entries.isEmpty)
        #expect(none.cursor == 3)
        #expect(again.entries.map(\.text) == ["two", "three"])
    }
}
