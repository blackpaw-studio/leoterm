import AppKit
import Testing
import WebKit

@testable import Ghostty
@testable import LeoKit

/// B-404: a download in the agent browser -- an attachment response or an
/// `<a download>` link -- is fetched into a private temp folder, then saved
/// into the agent's workspace (`downloads/`). A failed or cancelled fetch
/// leaves nothing, here or there.
@MainActor
@Suite(.serialized)
struct LeoWKBrowserDownloadTests {
    private static let pdf = Data("%PDF-1.4 fixture".utf8)
    private static let csv = Data("a,b\n1,2\n".utf8)

    private static let pages = [
        "links": """
        <title>Links</title>
        <a href="report.csv" download>Get report</a>
        <a href="report.csv" download target="_blank">Get report in a new tab</a>
        """,
    ]

    private static let files: [String: LeoWKFixtureFile] = [
        "x.pdf": LeoWKFixtureFile(data: pdf, mimeType: "application/pdf", attachmentName: "x.pdf"),
        "report.csv": LeoWKFixtureFile(data: csv, mimeType: "text/csv"),
        "big.zip": LeoWKFixtureFile(data: Data(count: 64 * 1024), mimeType: "application/zip", attachmentName: "big.zip", failsMidway: true),
    ]

    private nonisolated static let key = LeoAgentBrowserKey(host: .local, agent: "alpha")

    @available(macOS 14, *)
    @MainActor private struct Harness {
        let browser: LeoAgentBrowser
        let server: LeoHTTPFixtureServer
        let workspace: LeoFileSandbox
        let staging: LeoFileSandbox

        var log: LeoBrowserDownloads { browser.downloads }

        /// What is left in the browser's private download folder.
        func stagedFiles() -> [String] {
            (FileManager.default.subpaths(atPath: staging.path("root")) ?? []).filter { !$0.isEmpty }
        }

        func close() {
            browser.close()
            server.stop()
            workspace.cleanUp()
            staging.cleanUp()
        }
    }

    @available(macOS 14, *)
    private func harness() throws -> Harness {
        let workspace = try LeoFileSandbox()
        let staging = try LeoFileSandbox()
        let server = try LeoHTTPFixtureServer(pages: Self.pages, files: Self.files)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let log = LeoBrowserDownloads(saver: LeoBrowserDownloadSaver(makeAccess: { LeoFileAccessor.local() }), workspace: { workspace.root })
        let browser = LeoAgentBrowser(
            key: Self.key, configuration: configuration, urlMapping: LeoIdentityURLMapping(),
            input: LeoSyntheticInput(application: LeoWKTestHost.application),
            viewHost: LeoAgentBrowserHost(parking: LeoAgentBrowserParkingWindow(size: CGSize(width: 800, height: 600))),
            allowsURL: { url in ["http", "about"].contains(url.scheme ?? "") },
            downloads: LeoWKBrowserDownloads(log: log, temporaryRoot: URL(fileURLWithPath: staging.path("root")))
        )
        return Harness(browser: browser, server: server, workspace: workspace, staging: staging)
    }

    /// Waits (bounded) until the newest download satisfies `condition`.
    private func newest(
        in log: LeoBrowserDownloads, count: Int = 1, where condition: (LeoBrowserDownload) -> Bool
    ) async throws -> LeoBrowserDownload {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if log.entries.count >= count, let entry = log.entries.first, condition(entry) { return entry }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the download never got there: \(log.entries)")
        throw CancellationError()
    }

    private static func isFinished(_ entry: LeoBrowserDownload) -> Bool {
        if case .finished = entry.state { true } else { false }
    }

    private static func isFailed(_ entry: LeoBrowserDownload) -> Bool {
        if case .failed = entry.state { true } else { false }
    }

    @available(macOS 14, *)
    private func click(_ name: String, in browser: LeoAgentBrowser) async throws -> LeoClientToolOutcome {
        let page = try #require(browser.tabs.page(forTab: nil))
        let ref = try #require(leoSnapshotRef(try await page.snapshot(), name))
        return await browser.execute(LeoClientToolRequest(
            id: "ctr_click", agent: Self.key.agent, group: "browser", tool: "browser_click",
            args: .object(["ref": .string(ref)]), timeoutSeconds: 30
        ))
    }

    // MARK: - Tests

    @available(macOS 14, *)
    @Test(arguments: [
        ("attachment; filename=\"x.pdf\"", true, true),
        ("Attachment", true, true),
        ("inline", true, false),
        ("", true, false),
        ("", false, true),
    ])
    func attachmentsAndUnshowableTypesDownload(disposition: String, canShow: Bool, downloads: Bool) throws {
        let headers = disposition.isEmpty ? [:] : ["Content-Disposition": disposition]
        let response = try #require(HTTPURLResponse(url: URL(string: "https://a.test/x")!, statusCode: 200, httpVersion: nil, headerFields: headers))
        #expect(LeoWKBrowserPage.isDownload(response, canShowMIMEType: canShow) == downloads)
    }

    @available(macOS 14, *)
    @Test func attachmentResponseDownloadsIntoWorkspace() async throws {
        let h = try harness()
        defer { h.close() }
        let tab = try await h.browser.tabs.openTab(url: h.server.url("links"))
        let page = try #require(h.browser.tabs.page(forTab: tab))

        try await page.load(h.server.url("x.pdf"))
        let entry = try await newest(in: h.log, where: Self.isFinished)

        guard case .finished(let saved) = entry.state else { return }
        #expect(saved.path == h.workspace.path("downloads/x.pdf"))
        #expect(saved.workspacePath == "downloads/x.pdf")
        #expect(try Data(contentsOf: URL(fileURLWithPath: saved.path)) == Self.pdf)
        #expect(entry.sourceURL == h.server.url("x.pdf"))
        #expect(h.stagedFiles().isEmpty, "the private temp copy is removed")
        #expect(h.browser.tabs.downloads.map(\.id) == [entry.id])
    }

    /// The load ends as a download, not a failure or a timeout, and the
    /// tab stays on its page.
    @available(macOS 14, *)
    @Test func navigateToAttachmentReturnsOk() async throws {
        let h = try harness()
        defer { h.close() }
        let tab = try await h.browser.tabs.openTab(url: h.server.url("links"))
        let page = try #require(h.browser.tabs.page(forTab: tab))
        let started = ContinuousClock.now

        let code = await (page as? LeoWKBrowserPage)?.failureCode { try await $0.load(h.server.url("x.pdf")) }

        #expect(code == nil)
        #expect(ContinuousClock.now - started < LeoWKBrowserPage.navigationDeadline)
        #expect(page.url == h.server.url("links"))
        _ = try await newest(in: h.log, where: Self.isFinished)
    }

    @available(macOS 14, *)
    @Test func agentClickOnDownloadLinkSaves() async throws {
        let h = try harness()
        defer { h.close() }
        _ = try await h.browser.tabs.openTab(url: h.server.url("links"))

        #expect(try await click("link \"Get report\"", in: h.browser) == .success([.text("ok")]))
        _ = try await newest(in: h.log, where: Self.isFinished)
        #expect(try await click("link \"Get report in a new tab\"", in: h.browser) == .success([.text("ok")]))
        let second = try await newest(in: h.log, count: 2, where: Self.isFinished)

        guard case .finished(let saved) = second.state else { return }
        #expect(saved.workspacePath == "downloads/report 2.csv", "a clash is numbered, never overwritten")
        #expect(try h.workspace.names(in: "downloads") == ["report 2.csv", "report.csv"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: saved.path)) == Self.csv)
        #expect(h.stagedFiles().isEmpty)
    }

    @available(macOS 14, *)
    @Test func networkFailureLeavesNothingAndDeletesTemp() async throws {
        let h = try harness()
        defer { h.close() }
        let tab = try await h.browser.tabs.openTab(url: h.server.url("links"))
        let page = try #require(h.browser.tabs.page(forTab: tab))

        try await page.load(h.server.url("big.zip"))
        _ = try await newest(in: h.log) { entry in
            if case .downloading = entry.state { !h.stagedFiles().isEmpty } else { false }
        }
        h.server.failHeldLoads()
        let entry = try await newest(in: h.log, where: Self.isFailed)

        guard case .failed(let message) = entry.state else { return }
        #expect(message.hasPrefix("The download failed: "))
        #expect(message.hasSuffix("Nothing was saved."))
        #expect(try h.workspace.names().isEmpty, "nothing reaches the workspace")
        #expect(h.stagedFiles().isEmpty, "the partial temp file is deleted")
    }

    @available(macOS 14, *)
    @Test func closingTheTabCancelsAFetchAndLeavesNothing() async throws {
        let h = try harness()
        defer { h.close() }
        let tab = try await h.browser.tabs.openTab(url: h.server.url("links"))
        let page = try #require(h.browser.tabs.page(forTab: tab))
        try await page.load(h.server.url("big.zip"))
        _ = try await newest(in: h.log) { entry in
            if case .downloading = entry.state { !h.stagedFiles().isEmpty } else { false }
        }

        h.browser.tabs.closeTab(tab)
        let entry = try await newest(in: h.log, where: Self.isFailed)

        #expect(entry.state == .failed("The download failed: it was cancelled. Nothing was saved."))
        #expect(try h.workspace.names().isEmpty)
        #expect(h.stagedFiles().isEmpty)
    }
}
