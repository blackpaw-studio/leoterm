import Testing

@testable import Ghostty

/// Turning what an agent's terminal surfaces (a ⌘-clicked path or OSC 8
/// link, or text typed into Open File in Editor…) into an absolute path on
/// the agent's host.
struct LeoEditorLinkTests {
    // MARK: Which ⌘-clicked links the editor takes

    @Test(arguments: [
        ("/Users/e/app/main.swift", false),
        ("src/config/url.zig", false),
        ("./README.md:12", false),
        ("~/notes.md", false),
        ("file:///Users/e/app/main.swift", false),
        ("file:///Users/e/app/main.swift", true),
        ("FILE://studio.local/etc/hosts", true),
    ])
    func takesFileURLsAndBarePaths(_ url: String, isOSC8: Bool) {
        #expect(LeoEditorLink.fileReference(inOpenURL: url, isOSC8: isOSC8) == url)
    }

    @Test(arguments: [
        ("https://example.com/a.swift", false),
        ("https://example.com/a.swift", true),
        ("mailto:someone@example.com", false),
        ("ssh://host/path", false),
        // OSC 8 targets are URIs; a scheme-less one is left to Ghostty.
        ("/Users/e/app/main.swift", true),
        ("", false),
    ])
    func leavesEverythingElseToGhostty(_ url: String, isOSC8: Bool) {
        #expect(LeoEditorLink.fileReference(inOpenURL: url, isOSC8: isOSC8) == nil)
    }

    // MARK: Parsing

    @Test func absolutePathsAreNormalizedLexically() throws {
        #expect(try LeoEditorLink.parse("/Users/e/app/main.swift") == .init(base: .root, path: "/Users/e/app/main.swift"))
        #expect(try LeoEditorLink.parse("/a/./b/../c//d.swift") == .init(base: .root, path: "/a/c/d.swift"))
        #expect(try LeoEditorLink.parse("/../x") == .init(base: .root, path: "/x"))
        #expect(try LeoEditorLink.parse("  /padded.txt \n") == .init(base: .root, path: "/padded.txt"))
    }

    @Test func relativePathsAreWorkspaceRelative() throws {
        #expect(try LeoEditorLink.parse("src/a.swift") == .init(base: .workspace, path: "src/a.swift"))
        #expect(try LeoEditorLink.parse("./src/a.swift") == .init(base: .workspace, path: "src/a.swift"))
        #expect(try LeoEditorLink.parse("../shared/a.swift") == .init(base: .workspace, path: "../shared/a.swift"))
    }

    @Test func tildeIsTheHostsHome() throws {
        #expect(try LeoEditorLink.parse("~/notes.md") == .init(base: .home, path: "notes.md"))
        #expect(try LeoEditorLink.parse("~") == .init(base: .home, path: ""))
        // `~user` isn't expanded: it's a name like any other.
        #expect(try LeoEditorLink.parse("~bob/x") == .init(base: .workspace, path: "~bob/x"))
    }

    @Test func aTrailingLineAndColumnAreSplitOff() throws {
        #expect(try LeoEditorLink.parse("src/a.swift:42") == .init(base: .workspace, path: "src/a.swift", line: 42))
        #expect(try LeoEditorLink.parse("/a/b.zig:42:7") == .init(base: .root, path: "/a/b.zig", line: 42, column: 7))
        #expect(try LeoEditorLink.parse("src/a.swift:42:") == .init(base: .workspace, path: "src/a.swift", line: 42))
        #expect(try LeoEditorLink.parse("src/a.swift:0") == .init(base: .workspace, path: "src/a.swift:0"))
        #expect(try LeoEditorLink.parse("src/time:12x") == .init(base: .workspace, path: "src/time:12x"))
    }

    @Test func fileURLsArePercentDecodedAndIgnoreTheirHost() throws {
        #expect(try LeoEditorLink.parse("file:///Users/e/My%20Notes.md") == .init(base: .root, path: "/Users/e/My Notes.md"))
        // The link came from the agent's own terminal, so its host is the
        // agent's host whatever name it gives.
        #expect(try LeoEditorLink.parse("file://studio.local/Users/e/a.swift") == .init(base: .root, path: "/Users/e/a.swift"))
        #expect(try LeoEditorLink.parse("file://localhost/etc/hosts") == .init(base: .root, path: "/etc/hosts"))
        #expect(try LeoEditorLink.parse("FILE:///etc/hosts") == .init(base: .root, path: "/etc/hosts"))
        // A URL's path is exact: no line suffix.
        #expect(try LeoEditorLink.parse("file:///a/b:12") == .init(base: .root, path: "/a/b:12"))
    }

    @Test func emptyInputAndPathlessURLsAreRejected() {
        #expect(throws: LeoEditorLinkError.empty) { try LeoEditorLink.parse("") }
        #expect(throws: LeoEditorLinkError.empty) { try LeoEditorLink.parse("   ") }
        #expect(throws: LeoEditorLinkError.invalid("file://host")) { try LeoEditorLink.parse("file://host") }
        #expect(throws: LeoEditorLinkError.invalid("/a\0b")) { try LeoEditorLink.parse("/a\0b") }
    }

    // MARK: Resolving

    @Test func resolvesAgainstTheWorkspaceOrHome() throws {
        let workspace = "/Users/e/.leo/agents/app"
        #expect(try LeoEditorLink.parse("src/a.swift:3").resolve(workspace: workspace, home: nil)
            == LeoEditorLocation(path: "/Users/e/.leo/agents/app/src/a.swift", line: 3))
        #expect(try LeoEditorLink.parse("../other/b.go").resolve(workspace: workspace, home: nil)
            == LeoEditorLocation(path: "/Users/e/.leo/agents/other/b.go"))
        #expect(try LeoEditorLink.parse("~/notes.md").resolve(workspace: nil, home: "/home/e")
            == LeoEditorLocation(path: "/home/e/notes.md"))
        #expect(try LeoEditorLink.parse("~").resolve(workspace: nil, home: "/home/e") == LeoEditorLocation(path: "/home/e"))
        #expect(try LeoEditorLink.parse("/etc/hosts").resolve(workspace: nil, home: nil) == LeoEditorLocation(path: "/etc/hosts"))
    }

    @Test func aRelativePathNeedsAWorkspace() throws {
        #expect(throws: LeoEditorLinkError.noWorkspace) {
            try LeoEditorLink.parse("src/a.swift").resolve(workspace: nil, home: "/home/e")
        }
        #expect(throws: LeoEditorLinkError.noWorkspace) {
            try LeoEditorLink.parse("src/a.swift").resolve(workspace: "", home: "/home/e")
        }
    }

    @Test func onlyHomeLinksNeedTheHome() throws {
        #expect(try LeoEditorLink.parse("~/x").needsHome)
        #expect(try !LeoEditorLink.parse("/x").needsHome)
        #expect(try !LeoEditorLink.parse("x").needsHome)
    }

    @Test func errorsReadAsSentences() {
        #expect(LeoEditorLinkError.noWorkspace.localizedDescription
            == "This agent has no workspace, so a relative path can’t be opened. Use an absolute path.")
        #expect(LeoEditorLinkError.empty.localizedDescription == "Enter the path of a file to open.")
    }
}
