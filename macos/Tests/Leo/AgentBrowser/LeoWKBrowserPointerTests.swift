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

    /// Logs what a select's listeners see: `type:id:bubbles:composed:trusted`.
    private static let selectRecorder = """
    <script>
    window.events = [];
    for (const type of ['input', 'change'])
      document.addEventListener(type, e => events.push([e.type, e.target.id, e.bubbles, e.composed, e.isTrusted].join(':')), true);
    </script>
    """

    private static let selectPages = [
        "select": selectRecorder + """
        <title>Select</title>
        <select id="size" aria-label="Size">
          <option value="a">Alpha</option><option value="b">Beta</option><option value="c"> Gamma </option>
          <option value="Alpha">Zed</option><option value="locked" disabled>Locked</option>
        </select>
        <select id="tags" multiple aria-label="Tags">
          <option value="x" selected>X ray</option><option value="y">Yankee</option><option value="z">Zulu</option>
        </select>
        <select id="off" aria-label="Off"><option value="o">Only</option></select>
        <button id="plain">Plain</button>
        """,
    ]

    private func selectPage(_ fixture: LeoWKPageFixture) async throws -> LeoWKBrowserPage {
        _ = try await fixture.page.navigate(to: LeoWKFixtureServer.url("select"))
        return fixture.page
    }

    private func events(_ page: LeoWKBrowserPage) async throws -> [String] {
        let json = try await page.eval("window.events")
        return try JSONDecoder().decode([String].self, from: Data(json.utf8))
    }

    private func selectedValues(_ page: LeoWKBrowserPage, _ id: String) async throws -> [String] {
        let json = try await page.eval("Array.from(document.getElementById('\(id)').selectedOptions).map(o => o.value)")
        return try JSONDecoder().decode([String].self, from: Data(json.utf8))
    }

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

    // MARK: Select options

    @available(macOS 14, *)
    @Test func selectOptionMatchesValueBeforeLabelAndFiresInputThenChange() async throws {
        let fixture = LeoWKPageFixture(Self.pages.merging(Self.selectPages) { $1 })
        defer { fixture.close() }
        let page = try await selectPage(fixture)
        let ref = try #require(leoSnapshotRef(try await page.snapshot(), #"combobox "Size""#))

        let byValue = try await page.selectOption(ref: ref, values: ["b"])
        #expect(byValue == [LeoBrowserSelectedOption(value: "b", label: "Beta")])
        #expect(try await events(page) == ["input:size:true:true:false", "change:size:true:false:false"])

        let byLabel = try await page.selectOption(ref: ref, values: ["Gamma"])
        #expect(byLabel == [LeoBrowserSelectedOption(value: "c", label: "Gamma")])
        #expect(try await selectedValues(page, "size") == ["c"])

        // "Alpha" is the value of the fourth option and the label of the first: value wins.
        let clash = try await page.selectOption(ref: ref, values: ["Alpha"])
        #expect(clash == [LeoBrowserSelectedOption(value: "Alpha", label: "Zed")])
    }

    @available(macOS 14, *)
    @Test func selectOptionSetsAMultipleSelectToExactlyTheValuesPassed() async throws {
        let fixture = LeoWKPageFixture(Self.pages.merging(Self.selectPages) { $1 })
        defer { fixture.close() }
        let page = try await selectPage(fixture)
        let ref = try #require(leoSnapshotRef(try await page.snapshot(), #"listbox "Tags""#))
        #expect(try await selectedValues(page, "tags") == ["x"])

        let chosen = try await page.selectOption(ref: ref, values: ["Zulu", "y", "y"])

        #expect(chosen.map(\.value) == ["y", "z"])
        #expect(try await selectedValues(page, "tags") == ["y", "z"], "x is deselected; duplicates collapse")
    }

    @available(macOS 14, *)
    @Test func selectOptionRejectsInputThatCannotBeHonoured() async throws {
        let fixture = LeoWKPageFixture(Self.pages.merging(Self.selectPages) { $1 })
        defer { fixture.close() }
        let page = try await selectPage(fixture)
        let snapshot = try await page.snapshot()
        let size = try #require(leoSnapshotRef(snapshot, #"combobox "Size""#))
        let off = try #require(leoSnapshotRef(snapshot, #"combobox "Off""#))
        let plain = try #require(leoSnapshotRef(snapshot, #"button "Plain""#))

        _ = try await page.eval("document.getElementById('off').disabled = true")

        func message(_ ref: String, _ values: [String]) async -> String? {
            do {
                _ = try await page.selectOption(ref: ref, values: values)
                return nil
            } catch let error as LeoBrowserError {
                return "\(error.code.rawValue): \(error.message)"
            } catch {
                return "unexpected \(error)"
            }
        }
        let unknown = await message(size, ["nope"])
        #expect(unknown?.hasPrefix("invalid_args: No option \"nope\"") == true, "\(unknown ?? "nil")")
        #expect(unknown?.contains(#""b" (Beta)"#) == true, "the message lists the options: \(unknown ?? "nil")")
        #expect(await message(size, ["a", "b"])?.hasPrefix("invalid_args:") == true, "several values for a single select")
        #expect(await message(plain, ["a"])?.contains("is not a <select>") == true)
        #expect(await message(off, ["o"])?.contains("is disabled") == true)
        #expect(await message(size, ["locked"])?.contains("is disabled") == true, "a disabled option")
        #expect(try await events(page).isEmpty, "a refused call changes nothing and fires nothing")
        #expect(try await selectedValues(page, "size") == ["a"])
    }

    @available(macOS 14, *)
    @Test func selectOptionRejectsStaleRefs() async throws {
        let fixture = LeoWKPageFixture(Self.pages.merging(Self.selectPages) { $1 })
        defer { fixture.close() }
        let page = try await selectPage(fixture)
        let old = try #require(leoSnapshotRef(try await page.snapshot(), #"combobox "Size""#))
        _ = try await page.snapshot()
        #expect(await page.failureCode { try await $0.selectOption(ref: old, values: ["a"]) } == "stale_ref")
        #expect(await page.failureCode { try await $0.selectOption(ref: "s999e1", values: ["a"]) } == "stale_ref")
        #expect(try await events(page).isEmpty)
    }

    // MARK: Drag

    /// Draggables log `type:id:trusted` for the drag events; the drop target
    /// reads back what `dragstart` stored.
    private static let dragRecorder = """
    <script>
    window.events = [];
    for (const type of ['dragstart', 'drag', 'dragenter', 'dragover', 'dragleave', 'drop', 'dragend']) {
      document.addEventListener(type, e => {
        events.push(type + ':' + e.target.id + ':' + e.isTrusted);
        if (type === 'dragstart') e.dataTransfer.setData('text/plain', 'card-7');
        if (type === 'dragover' && e.target.closest('#accepting')) e.preventDefault();
        if (type === 'drop') window.dropped = e.dataTransfer.getData('text/plain');
      }, true);
    }
    </script>
    <style>
    div { position: absolute; width: 120px; height: 60px }
    #card { left: 20px; top: 20px; background: #acf } #accepting { left: 300px; top: 20px; background: #cfa }
    #refusing { left: 300px; top: 200px; background: #fca }
    </style>
    """

    private static let dragPages = [
        "drag": dragRecorder + """
        <title>Drag</title>
        <div id="card" draggable="true" role="button" tabindex="0">Card</div>
        <div id="accepting" role="button" tabindex="0"><span id="inner">Drop here</span></div>
        <div id="refusing" role="button" tabindex="0">Not here</div>
        """,
        "pointer": """
        <title>Pointer</title>
        <script>
        window.log = [];
        for (const type of ['pointerdown', 'mousedown', 'pointermove', 'mousemove', 'pointerup', 'mouseup'])
          document.addEventListener(type, e => log.push([type, e.target.id, e.isTrusted, e.buttons].join(':')), true);
        </script>
        <style>
        div { position: absolute; width: 120px; height: 60px }
        #thumb { left: 20px; top: 300px; background: #ccc } #track { left: 300px; top: 300px; background: #eee }
        </style>
        <div id="thumb" role="button" tabindex="0">Thumb</div><div id="track" role="button" tabindex="0">Track</div>
        """,
    ]

    private func dragEvents(_ page: LeoWKBrowserPage) async throws -> [String] {
        let json = try await page.eval("window.events")
        return try JSONDecoder().decode([String].self, from: Data(json.utf8))
    }

    @available(macOS 14, *)
    @Test func html5DragDropsDataOnATargetThatAcceptsIt() async throws {
        let fixture = LeoWKPageFixture(Self.dragPages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("drag"))
        let snapshot = try await page.snapshot()
        let card = try #require(leoSnapshotRef(snapshot, #"button "Card""#))
        let target = try #require(leoSnapshotRef(snapshot, #"button "Drop here""#))

        try await page.drag(startRef: card, endRef: target)

        let events = try await dragEvents(page)
        #expect(events == [
            "dragstart:card:false", "drag:card:false", "dragenter:accepting:false", "drag:card:false", "dragover:accepting:false",
            "drop:accepting:false", "dragend:card:false",
        ], "\(events)")
        #expect(try await page.eval("window.dropped") == #""card-7""#, "the drop reads what dragstart stored")
    }

    @available(macOS 14, *)
    @Test func html5DragOntoATargetThatRefusesSendsNoDrop() async throws {
        let fixture = LeoWKPageFixture(Self.dragPages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("drag"))
        let snapshot = try await page.snapshot()
        let card = try #require(leoSnapshotRef(snapshot, #"button "Card""#))
        let refusing = try #require(leoSnapshotRef(snapshot, #"button "Not here""#))

        try await page.drag(startRef: card, endRef: refusing)

        let events = try await dragEvents(page)
        #expect(!events.contains { $0.hasPrefix("drop:") }, "\(events)")
        #expect(events.contains("dragleave:refusing:false") && events.last == "dragend:card:false", "\(events)")
    }

    @available(macOS 14, *)
    @Test func pointerDragPressesMovesAndReleasesOnTheTarget() async throws {
        let fixture = LeoWKPageFixture(Self.dragPages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("pointer"))
        let snapshot = try await page.snapshot()
        let thumb = try #require(leoSnapshotRef(snapshot, #"button "Thumb""#))
        let track = try #require(leoSnapshotRef(snapshot, #"button "Track""#))

        try await page.drag(startRef: thumb, endRef: track)

        let json = try await page.eval("window.log")
        let log = try JSONDecoder().decode([String].self, from: Data(json.utf8)).map { $0.split(separator: ":", omittingEmptySubsequences: false).map(String.init) }
        #expect(log.allSatisfy { $0[2] == "true" }, "every event is trusted: \(log)")
        #expect(log.first?[0] == "pointerdown" && log.first?[1] == "thumb", "\(log)")
        // WebKit reports `buttons` from the hardware, which no synthesized event can change, so it reads 0 here.
        let order = log.map { $0[0] }
        let down = try #require(order.firstIndex(of: "pointerdown"))
        let up = try #require(order.firstIndex(of: "pointerup"))
        let moves = order[down..<up].filter { $0 == "pointermove" }
        #expect(moves.count >= LeoWKBrowserPage.dragSteps / 2, "moves between the press and the release: \(log)")
        #expect(log.last?[0] == "mouseup" && log.last?[1] == "track", "released over the target: \(log)")
        #expect(log.contains { $0[0] == "pointerup" && $0[1] == "track" })
    }

    @available(macOS 14, *)
    @Test func dragRejectsStaleRefsBeforeSendingAnything() async throws {
        let fixture = LeoWKPageFixture(Self.dragPages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("pointer"))
        let snapshot = try await page.snapshot()
        let thumb = try #require(leoSnapshotRef(snapshot, #"button "Thumb""#))
        let track = try #require(leoSnapshotRef(snapshot, #"button "Track""#))
        _ = try await page.eval("document.getElementById('track').remove()")

        #expect(await page.failureCode { try await $0.drag(startRef: thumb, endRef: track) } == "stale_ref", "a detached end")
        #expect(await page.failureCode { try await $0.drag(startRef: thumb, endRef: "s999e1") } == "stale_ref", "an old end")
        #expect(await page.failureCode { try await $0.drag(startRef: "s999e1", endRef: thumb) } == "stale_ref", "an old start")
        #expect(try await page.eval("window.log.length") == "0", "no pointerdown for a stale end ref")
    }

    @available(macOS 14, *)
    @Test func draggingAnElementOntoItselfDoesNothing() async throws {
        let fixture = LeoWKPageFixture(Self.dragPages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("pointer"))
        let thumb = try #require(leoSnapshotRef(try await page.snapshot(), #"button "Thumb""#))
        try await page.drag(startRef: thumb, endRef: thumb)
        #expect(try await page.eval("window.log.length") == "0")
    }
}
