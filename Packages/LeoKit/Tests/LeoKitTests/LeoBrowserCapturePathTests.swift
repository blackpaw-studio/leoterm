import Foundation
import Testing

@testable import LeoKit

/// Where an agent's or the user's page capture lands in the workspace.
struct LeoBrowserCapturePathTests {
    private func resolve(
        _ path: String?, workspace: String = "/ws", kind: LeoBrowserCaptureKind = .pdf, defaultName: String = "Page.pdf"
    ) throws -> LeoBrowserCaptureTarget {
        try LeoBrowserCapturePath.resolve(path, workspace: workspace, kind: kind, defaultName: defaultName)
    }

    private func rejects(_ path: String, workspace: String = "/ws", kind: LeoBrowserCaptureKind = .pdf, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            let target = try resolve(path, workspace: workspace, kind: kind)
            Issue.record("\(path.debugDescription) resolved to \(target)", sourceLocation: sourceLocation)
        } catch let error as LeoBrowserError {
            #expect(error.code == .invalidArgs, "\(path.debugDescription): \(error)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("\(path.debugDescription) threw \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func noPathGoesToDownloadsUnderTheDefaultName() throws {
        #expect(try resolve(nil) == LeoBrowserCaptureTarget(folder: "downloads", name: "Page.pdf"))
    }

    @Test func relativePathSplitsIntoFolderAndName() throws {
        #expect(try resolve("shots/today/a.pdf") == LeoBrowserCaptureTarget(folder: "shots/today", name: "a.pdf"))
        #expect(try resolve("a.pdf") == LeoBrowserCaptureTarget(folder: "", name: "a.pdf"))
        #expect(try resolve("a.pdf").workspacePath == "a.pdf")
        #expect(try resolve("shots/a.pdf").workspacePath == "shots/a.pdf")
    }

    @Test func trailingSlashUsesDefaultName() throws {
        #expect(try resolve("shots/") == LeoBrowserCaptureTarget(folder: "shots", name: "Page.pdf"))
        #expect(try resolve("shots/today/", kind: .png, defaultName: "Page.png") == LeoBrowserCaptureTarget(folder: "shots/today", name: "Page.png"))
    }

    @Test func missingExtensionIsAppended() throws {
        #expect(try resolve("shots/a").name == "a.pdf")
        #expect(try resolve("shots/a", kind: .png).name == "a.png")
        #expect(try resolve("Node.js — Docs").name == "Node.js — Docs.pdf", "a dotted name with no real extension")
        #expect(try resolve("a.PDF").name == "a.PDF", "the expected extension in any case is kept")
    }

    @Test func wrongExtensionIsRejected() {
        rejects("a.png")
        rejects("shots/a.pdf", kind: .png)
        rejects("a.txt")
    }

    @Test(arguments: [
        "", "..", "../a.pdf", "a/../b.pdf", "a/../../b.pdf", "./a.pdf", "a/./b.pdf", "a//b.pdf", "//a.pdf",
        "a\0b.pdf", "a\nb.pdf", "shots/\u{1B}x.pdf", ".a.pdf.leo-0123456789abcdef0123456789abcdef.tmp",
    ])
    func escapesAreRejected(path: String) {
        rejects(path)
    }

    @Test func absolutePathInsideWorkspaceIsAccepted() throws {
        #expect(try resolve("/ws/shots/a.pdf") == LeoBrowserCaptureTarget(folder: "shots", name: "a.pdf"))
        #expect(try resolve("/ws/a.pdf") == LeoBrowserCaptureTarget(folder: "", name: "a.pdf"))
        #expect(try resolve("/ws/") == LeoBrowserCaptureTarget(folder: "", name: "Page.pdf"))
        #expect(try resolve("/ws/shots/a.pdf", workspace: "/ws/") == LeoBrowserCaptureTarget(folder: "shots", name: "a.pdf"))
    }

    @Test(arguments: ["/etc/a.pdf", "/wsx/a.pdf", "/ws", "/ws/../etc/a.pdf", "/a.pdf"])
    func absolutePathOutsideWorkspaceIsRejected(path: String) {
        rejects(path)
    }

    @Test func theFormIsCheckedWithoutAWorkspace() {
        #expect(throws: LeoBrowserError.self) { try LeoBrowserCapturePath.validate("../a.pdf", kind: .pdf) }
        #expect(throws: LeoBrowserError.self) { try LeoBrowserCapturePath.validate("a.png", kind: .pdf) }
        #expect(throws: Never.self) { try LeoBrowserCapturePath.validate("/anywhere/a.pdf", kind: .pdf) }
        #expect(throws: Never.self) { try LeoBrowserCapturePath.validate("shots/", kind: .pdf) }
    }

    @Test func defaultNameIsSanitisedTitleElseHostElsePage() {
        #expect(LeoBrowserCapturePath.defaultName(title: "Example Domain", host: "example.com", kind: .pdf) == "Example Domain.pdf")
        #expect(LeoBrowserCapturePath.defaultName(title: "a/b: c", host: nil, kind: .png) == "a_b: c.png")
        #expect(LeoBrowserCapturePath.defaultName(title: "  ", host: "example.com", kind: .pdf) == "example.com.pdf")
        #expect(LeoBrowserCapturePath.defaultName(title: "...", host: "example.com", kind: .pdf) == "example.com.pdf")
        #expect(LeoBrowserCapturePath.defaultName(title: "", host: nil, kind: .pdf) == "page.pdf")
        #expect(LeoBrowserCapturePath.defaultName(title: "", host: "", kind: .png) == "page.png")
        #expect(LeoBrowserCapturePath.defaultName(title: "report.pdf", host: nil, kind: .pdf) == "report.pdf", "a PDF's own name is not doubled")
        let long = LeoBrowserCapturePath.defaultName(title: String(repeating: "é", count: 300), host: nil, kind: .pdf)
        #expect(long.utf8.count <= LeoBrowserDownloadName.maximumBytes)
        #expect(long.hasSuffix(".pdf"))
    }

    @Test func theProblemIsASentenceForTheSaveSheet() {
        #expect(LeoBrowserCapturePath.problem(with: "a.png", kind: .pdf, workspace: "/ws") == "The path must end in .pdf.")
        #expect(LeoBrowserCapturePath.problem(with: "", kind: .pdf, workspace: "/ws") == "The path is empty.")
        #expect(LeoBrowserCapturePath.problem(with: "/etc/a.pdf", kind: .pdf, workspace: "/ws") == "The path is outside the workspace (/ws).")
        #expect(LeoBrowserCapturePath.problem(with: "/etc/a.pdf", kind: .pdf, workspace: nil) == nil, "no workspace yet: the form only")
        #expect(LeoBrowserCapturePath.problem(with: "downloads/a", kind: .pdf, workspace: "/ws") == nil)
    }

    @Test func theNameIsMadeSafeAsADownloadsIs() throws {
        #expect(try resolve("shots/ a\\b.pdf").name == "a_b.pdf")
        #expect(try resolve(".hidden.pdf").name == "hidden.pdf")
    }
}
