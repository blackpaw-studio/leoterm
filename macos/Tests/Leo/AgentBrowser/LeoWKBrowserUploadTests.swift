import AppKit
import Testing
import WebKit

@testable import Ghostty
@testable import LeoKit

/// `browser_upload` in a real `WKWebView`: the snapshot lists file inputs
/// (hidden ones too), and files set from Leo's isolated world reach the
/// page's own scripts with their bytes, after `input` and `change`.
@MainActor
@Suite(.serialized)
struct LeoWKBrowserUploadTests {
    /// Each input records its events and, on change, what the page itself
    /// reads back from the files: name, type and bytes.
    private static let recorder = """
    <script>
    window.events = [];
    window.read = null;
    document.addEventListener('input', e => events.push('input:' + e.target.id), true);
    document.addEventListener('change', async e => {
      events.push('change:' + e.target.id);
      window.read = await Promise.all(Array.from(e.target.files).map(async f => ({
        name: f.name, type: f.type, bytes: Array.from(new Uint8Array(await f.arrayBuffer()))
      })));
    }, true);
    </script>
    """

    private static let pages = [
        "single": recorder + """
        <title>Single</title>
        <label>Avatar <input type="file" id="avatar" accept="image/*"></label>
        <input id="note" aria-label="Note">
        """,
        "multiple": recorder + """
        <title>Multiple</title>
        <input type="file" id="docs" aria-label="Documents" multiple>
        """,
        "hidden": recorder + """
        <title>Hidden</title>
        <button onclick="document.getElementById('pick').click()">Upload photo</button>
        <input type="file" id="pick" name="photo" style="display:none">
        <input type="file" id="clear" aria-label="Invisible" style="opacity:0;position:absolute;width:1px;height:1px">
        <div aria-hidden="true"><input type="file" id="buried" aria-label="Buried"></div>
        """,
        "label": recorder + """
        <title>Label</title>
        <label for="doc" tabindex="0">Attach document</label>
        <input type="file" id="doc" hidden>
        <div role="button" tabindex="0">Drop a file<input type="file" id="inner" hidden></div>
        <div role="button" tabindex="0">Two inputs<input type="file" hidden><input type="file" hidden></div>
        """,
        "fieldset": recorder + """
        <title>Fieldset</title>
        <fieldset disabled><legend>Locked</legend>
        <div role="button" tabindex="0">Attach contract<input type="file" id="contract" aria-label="Contract file"></div>
        </fieldset>
        """,
    ]

    private static let png = LeoBrowserUploadFile(
        name: "face.png", mimeType: "image/png", data: Data((0...255).map(UInt8.init)), workspacePath: "img/face.png"
    )

    private struct Read: Decodable, Equatable {
        let name: String
        let type: String
        let bytes: [UInt8]
    }

    private func read(_ page: LeoWKBrowserPage) async throws -> [Read] {
        for _ in 0..<100 {
            let json = try await page.eval("window.read")
            if json != "null" { return try JSONDecoder().decode([Read].self, from: Data(json.utf8)) }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the page never read the files")
        return []
    }

    @available(macOS 14, *)
    @Test func setFilesFiresInputAndChangeAndPageWorldReadsBytes() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("single"))
        let snapshot = try await page.snapshot()
        #expect(snapshot.contains(#"button "Avatar" [ref="#))
        #expect(snapshot.contains("[file] [accept=image/*]"))
        #expect(!snapshot.contains(#"textbox "Avatar""#), "a file input is not a text box")
        let ref = try #require(leoSnapshotRef(snapshot, #"button "Avatar""#))

        #expect(try await page.fileInput(ref: ref) == LeoBrowserFileInput(allowsMultiple: false))
        try await page.setFiles(ref: ref, files: [Self.png])

        #expect(try await read(page) == [Read(name: "face.png", type: "image/png", bytes: Array(0...255))])
        #expect(try await page.eval("events") == #"["input:avatar","change:avatar"]"#)
        #expect(try await page.snapshot().contains(#": "face.png""#), "the snapshot shows what the input holds")
    }

    @available(macOS 14, *)
    @Test func multipleInputTakesSeveralFiles() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("multiple"))
        let snapshot = try await page.snapshot()
        #expect(snapshot.contains("[file] [multiple]"))
        let ref = try #require(leoSnapshotRef(snapshot, #"button "Documents""#))
        let text = LeoBrowserUploadFile(name: "a.txt", mimeType: "text/plain", data: Data("hello".utf8), workspacePath: "a.txt")

        #expect(try await page.fileInput(ref: ref) == LeoBrowserFileInput(allowsMultiple: true))
        try await page.setFiles(ref: ref, files: [text, Self.png])

        let files = try await read(page)
        #expect(files.map(\.name) == ["a.txt", "face.png"])
        #expect(files.first?.bytes == Array("hello".utf8))
    }

    @available(macOS 14, *)
    @Test func hiddenFileInputIsInSnapshotAndUploadable() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("hidden"))
        let snapshot = try await page.snapshot()
        let ref = try #require(leoSnapshotRef(snapshot, #"button "photo""#), "named from its name attribute")
        #expect(snapshot.contains(#"button "photo" [ref=\#(ref)] [file] [hidden]"#))
        #expect(leoSnapshotRef(snapshot, #"button "Invisible""#) != nil)
        #expect(leoSnapshotRef(snapshot, #"button "Buried""#) != nil, "under aria-hidden, still listed")

        try await page.setFiles(ref: ref, files: [Self.png])

        #expect(try await read(page).map(\.name) == ["face.png"])
        #expect(try await page.eval("events") == #"["input:pick","change:pick"]"#)
    }

    @available(macOS 14, *)
    @Test func labelRefResolvesToItsInput() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("label"))
        let snapshot = try await page.snapshot()
        let label = try #require(leoSnapshotRef(snapshot, #"clickable "Attach document""#))
        let container = try #require(leoSnapshotRef(snapshot, #"button "Drop a file""#))

        try await page.setFiles(ref: label, files: [Self.png])
        #expect(try await read(page).map(\.name) == ["face.png"])
        #expect(try await page.eval("events") == #"["input:doc","change:doc"]"#)

        _ = try await page.eval("window.read = null; window.events = []; null")
        try await page.setFiles(ref: container, files: [Self.png])
        #expect(try await read(page).map(\.name) == ["face.png"])
        #expect(try await page.eval("events") == #"["input:inner","change:inner"]"#)
    }

    @available(macOS 14, *)
    @Test func nonFileInputRefIsInvalidArgs() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("single"))
        let snapshot = try await page.snapshot()
        let note = try #require(leoSnapshotRef(snapshot, #"textbox "Note""#))

        #expect(await page.failureCode { try await $0.fileInput(ref: note) } == "invalid_args")
        #expect(await page.failureCode { try await $0.setFiles(ref: note, files: [Self.png]) } == "invalid_args")
        #expect(await page.failureCode { try await $0.fileInput(ref: "s99e1") } == "stale_ref")

        _ = try await page.navigate(to: LeoWKFixtureServer.url("label"))
        let twoInputs = try #require(leoSnapshotRef(try await page.snapshot(), #"button "Two inputs""#))
        #expect(await page.failureCode { try await $0.fileInput(ref: twoInputs) } == "invalid_args")
        #expect(try await page.eval("events") == "[]", "nothing was set")
    }

    /// An input disabled by its `<fieldset disabled>` is disabled to the
    /// browser even though its own `disabled` is false: no ref, no upload.
    @available(macOS 14, *)
    @Test func inputInDisabledFieldsetIsDisabled() async throws {
        let fixture = LeoWKPageFixture(Self.pages)
        defer { fixture.close() }
        let page = fixture.page
        _ = try await page.navigate(to: LeoWKFixtureServer.url("fieldset"))
        let snapshot = try await page.snapshot()
        #expect(snapshot.contains(#"button "Contract file" [file] [disabled]"#))
        #expect(leoSnapshotRef(snapshot, #"button "Contract file""#) == nil)
        let container = try #require(leoSnapshotRef(snapshot, #"button "Attach contract""#))

        #expect(await page.failureCode { try await $0.fileInput(ref: container) } == "invalid_args")
        #expect(await page.failureCode { try await $0.setFiles(ref: container, files: [Self.png]) } == "invalid_args")
        #expect(try await page.eval("events") == "[]", "nothing was set")
    }
}
