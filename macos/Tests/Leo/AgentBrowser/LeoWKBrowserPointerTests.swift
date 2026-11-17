import AppKit
import Testing
import WebKit

@testable import Ghostty
@testable import LeoKit

/// `browser_hover`, `browser_select_option` and `browser_drag` in a real
/// `WKWebView`: the page's own listeners see the events, and the events
/// are the kind a user's pointer makes (`isTrusted`, in order).
@MainActor
@Suite(.serialized)
struct LeoWKBrowserPointerTests {
    /// Logs what the page sees: `type:id:trusted` per event of interest.
    private static let recorder = """
    <script>
    window.log = [];
    const note = e => log.push(e.type + ':' + (e.target.id || e.target.tagName) + ':' + e.isTrusted);
    for (const type of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'mousemove', 'pointermove'])
      document.addEventListener(type, note, true);
    </script>
    """

    private static let pages = [
        "hover": recorder + """
        <title>Hover</title>
        <style>
        #menu { display: none } #host:hover #menu { display: block }
        #host { padding: 20px }
        </style>
        <div id="host"><button id="trigger">Products</button><ul id="menu"><li><a href="#x">Pricing</a></li></ul></div>
        <button id="other">Elsewhere</button>
        """,
    ]

    private func log(_ page: LeoWKBrowserPage) async throws -> [String] {
        let json = try await page.eval("window.log")
        return try JSONDecoder().decode([String].self, from: Data(json.utf8))
    }

    @available(macOS 14, *)
    @Test func hoverFiresTrustedMoveEventsAndAppliesHoverStyles() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("hover"))
        let before = try await page.snapshot()
        #expect(!before.contains("Pricing"))
        let ref = try #require(leoSnapshotRef(before, #"button "Products""#))

        try await page.hover(ref: ref)

        let events = try await log(page)
        #expect(events.allSatisfy { $0.hasSuffix(":true") }, "\(events)")
        for expected in ["pointerover:trigger", "mouseover:trigger", "mouseenter:trigger", "pointermove:trigger", "mousemove:trigger"] {
            #expect(events.contains { $0.hasPrefix(expected) }, "\(expected) in \(events)")
        }
        #expect(events.firstIndex { $0.hasPrefix("mouseover") }! < events.firstIndex { $0.hasPrefix("mousemove") }!, "\(events)")
        // `matches(':hover')` stays false while the page's window is not key; the styles apply.
        #expect(try await page.eval(#"getComputedStyle(document.getElementById('menu')).display"#) == #""block""#)
        #expect(try await page.snapshot().contains("Pricing"), "the hover menu shows in a new snapshot")
    }

    @available(macOS 14, *)
    @Test func hoverRejectsStaleRefs() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("hover"))
        let old = try #require(leoSnapshotRef(try await page.snapshot(), #"button "Products""#))
        _ = try await page.snapshot()
        #expect(await page.failureCode { try await $0.hover(ref: old) } == "stale_ref")
        #expect(await page.failureCode { try await $0.hover(ref: "s999e1") } == "stale_ref")
        #expect(try await log(page).isEmpty)
    }
}
