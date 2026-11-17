import AppKit
import Testing
import WebKit

@testable import Ghostty
@testable import LeoKit

/// A page's file input reaches the injected chooser with the page's
/// flags, and the page's completion handler fires exactly once.
@MainActor
@Suite(.serialized)
struct LeoBrowserFilePickerTests {
    @MainActor private final class FakePicker: LeoBrowserFilePicking {
        typealias Request = LeoBrowserFilePickRequest

        private(set) var requests: [Request] = []
        private(set) var dismissCount = 0
        private var completions: [@MainActor ([URL]?) -> Void] = []

        func present(
            _ request: LeoBrowserFilePickRequest,
            completion: @escaping @MainActor ([URL]?) -> Void
        ) -> any LeoBrowserFilePickSession {
            requests.append(request)
            completions.append(completion)
            return Session(picker: self)
        }

        func answer(_ urls: [URL]?) { completions.last?(urls) }

        private struct Session: LeoBrowserFilePickSession {
            let picker: FakePicker

            func dismiss() { picker.dismissCount += 1 }
        }
    }

    @available(macOS 14, *)
    private func makeTabs(_ picker: any LeoBrowserFilePicking) -> LeoAgentBrowserTabs {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return LeoAgentBrowserTabs(
            agentName: "alpha", configuration: configuration, allowsURL: { _ in true },
            input: LeoSyntheticInput(application: LeoWKTestHost.application),
            viewHost: LeoAgentBrowserHost(parking: LeoAgentBrowserParkingWindow(size: CGSize(width: 800, height: 600))),
            filePicker: picker, downloader: LeoWKBrowserDownloads(log: .withoutWorkspace())
        )
    }

    @available(macOS 14, *)
    private func choose(
        _ tabs: LeoAgentBrowserTabs, on tab: Int, multiple: Bool = false, directories: Bool = false, origin: String = "example.com",
        _ results: ResultBox
    ) throws {
        let webView = try #require((tabs.page(forTab: tab) as? LeoWKBrowserPage)?.webView)
        tabs.chooseFiles(for: webView, origin: origin, allowsMultipleSelection: multiple, allowsDirectories: directories) { results.urls.append($0) }
    }

    @MainActor private final class RecordingPresenter: LeoBrowserUploadPanelPresenting {
        private(set) var shown: [LeoBrowserWorkspacePick] = []
        private(set) var dismissed = 0

        func show(_ pick: LeoBrowserWorkspacePick) -> any LeoBrowserUploadPanelHandle {
            shown.append(pick)
            return Handle(presenter: self)
        }

        private struct Handle: LeoBrowserUploadPanelHandle {
            let presenter: RecordingPresenter
            func dismiss() { presenter.dismissed += 1 }
        }
    }

    @MainActor private final class ResultBox {
        var urls: [[URL]?] = []
    }

    @available(macOS 14, *)
    @Test func forwardsTheMultiSelectAndDirectoryFlags() async throws {
        let picker = FakePicker()
        let tabs = makeTabs(picker)
        defer { tabs.closeAll() }
        let tab = try await tabs.openTab(url: LeoAgentBrowserTabs.blank)
        try choose(tabs, on: tab, multiple: true, directories: true, ResultBox())
        try choose(tabs, on: tab, ResultBox())
        #expect(picker.requests.map(\.allowsMultipleSelection) == [true, false])
        #expect(picker.requests.map(\.allowsDirectories) == [true, false])
    }

    @available(macOS 14, *)
    @Test func tellsThePanelWhichAgentAndSiteAsked() async throws {
        let picker = FakePicker()
        let tabs = makeTabs(picker)
        defer { tabs.closeAll() }
        let tab = try await tabs.openTab(url: LeoAgentBrowserTabs.blank)
        try choose(tabs, on: tab, origin: "shop.example:8443", ResultBox())
        try choose(tabs, on: tab, directories: true, origin: "shop.example:8443", ResultBox())
        let requests = picker.requests
        #expect(requests.map(\.agent) == ["alpha", "alpha"])
        #expect(requests.map(\.origin) == ["shop.example:8443", "shop.example:8443"])
        #expect(requests.map(\.message) == [
            "alpha · shop.example:8443 wants to upload a file",
            "alpha · shop.example:8443 wants to upload a folder",
        ])
    }

    @Test func labelsAnOriginByHostAndNonDefaultPort() {
        #expect(LeoBrowserFilePickRequest.originLabel(host: "example.com", port: 0) == "example.com")
        #expect(LeoBrowserFilePickRequest.originLabel(host: "localhost", port: 3000) == "localhost:3000")
        #expect(LeoBrowserFilePickRequest.originLabel(host: "", port: 0) == "this page")
    }

    @available(macOS 14, *)
    @Test func passesTheChosenURLsThrough() async throws {
        let picker = FakePicker()
        let tabs = makeTabs(picker)
        defer { tabs.closeAll() }
        let tab = try await tabs.openTab(url: LeoAgentBrowserTabs.blank)
        let results = ResultBox()
        try choose(tabs, on: tab, multiple: true, results)
        let chosen = [URL(filePath: "/tmp/a.txt"), URL(filePath: "/tmp/b.txt")]
        picker.answer(chosen)
        #expect(results.urls == [chosen])
    }

    @available(macOS 14, *)
    @Test func cancelAnswersNil() async throws {
        let picker = FakePicker()
        let tabs = makeTabs(picker)
        defer { tabs.closeAll() }
        let tab = try await tabs.openTab(url: LeoAgentBrowserTabs.blank)
        let results = ResultBox()
        try choose(tabs, on: tab, results)
        #expect(picker.requests.count == 1)
        #expect(results.urls.isEmpty)
        picker.answer(nil)
        #expect(results.urls.count == 1)
        #expect(results.urls[0] == nil)
    }

    @available(macOS 14, *)
    @Test func closingTheTabMidPanelAnswersOnceAndDismissesThePanel() async throws {
        let picker = FakePicker()
        let tabs = makeTabs(picker)
        let tab = try await tabs.openTab(url: LeoAgentBrowserTabs.blank)
        let results = ResultBox()
        try choose(tabs, on: tab, results)
        tabs.closeTab(tab)
        picker.answer([URL(filePath: "/tmp/late.txt")])
        #expect(results.urls.count == 1)
        #expect(results.urls[0] == nil)
        #expect(picker.dismissCount == 1)
    }

    @available(macOS 14, *)
    @Test func closingTheTabAbandonsTheWorkspacePickerAndAnswersOnce() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("leo-pick-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let presenter = RecordingPresenter()
        let mac = FakePicker()
        let picker = LeoBrowserWorkspaceFilePicker(
            host: .local, agent: "alpha", workspace: { workspace.path }, makeAccess: { _ in LeoFileAccessor.local() },
            fallback: mac, presenter: presenter, stagingRoot: workspace.appendingPathComponent("staging")
        )
        let tabs = makeTabs(picker)
        let tab = try await tabs.openTab(url: LeoAgentBrowserTabs.blank)
        let results = ResultBox()
        try choose(tabs, on: tab, results)
        let pick = try #require(presenter.shown.first)

        tabs.closeTab(tab)
        pick.cancel()
        pick.chooseFromMac()

        #expect(results.urls.count == 1)
        #expect(results.urls.first == .some(nil))
        #expect(presenter.dismissed == 1)
        #expect(pick.isFinished)
        #expect(mac.requests.isEmpty, "a closed tab never hands over to the Mac panel")
    }
}
