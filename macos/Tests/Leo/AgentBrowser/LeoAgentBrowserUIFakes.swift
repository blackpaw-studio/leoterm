import AppKit
import Foundation
import LeoKit

@testable import Ghostty

/// A tab set with no pages, for UI tests.
@MainActor final class FakeBrowserTabs: LeoBrowserTabs {
    var tabs: [LeoBrowserTabInfo] = []
    private(set) var opened: [URL] = []
    private(set) var selected: [Int] = []
    private(set) var closed: [Int] = []

    func page(forTab id: Int?) -> (any LeoBrowserPage)? { nil }

    func openTab(url: URL) async throws -> Int {
        opened.append(url)
        return 1
    }

    func selectTab(_ id: Int) { selected.append(id) }
    func closeTab(_ id: Int) { closed.append(id) }
}

/// A scriptable pane source: tests set its state and call `changed()`.
@MainActor final class FakePaneSource: LeoAgentBrowserPaneSource {
    let fakeTabs = FakeBrowserTabs()
    let control = LeoBrowserControlModel()
    var tabs: any LeoBrowserTabs { fakeTabs }
    var activeView: NSView?
    var activeRemoteURL: URL?
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    private(set) var calls: [String] = []
    private var handlers: [UUID: @MainActor () -> Void] = [:]

    func goBack() { calls.append("back") }
    func goForward() { calls.append("forward") }
    func reload() { calls.append("reload") }
    func navigate(to url: URL) { calls.append("navigate \(url.absoluteString)") }
    func openBlankTab() { calls.append("newTab") }

    func observe(_ handler: @escaping @MainActor () -> Void) -> () -> Void {
        let id = UUID()
        handlers[id] = handler
        return { [weak self] in self?.handlers[id] = nil }
    }

    func changed() { handlers.values.forEach { $0() } }
}

@MainActor final class FakePresence: LeoAgentBrowserPresence {
    private var browsers: [LeoAgentBrowserKey: FakePaneSource] = [:]
    private var handlers: [UUID: @MainActor (LeoAgentBrowserPresenceChange) -> Void] = [:]
    private(set) var closeRequests: [LeoAgentBrowserKey] = []

    var keys: Set<LeoAgentBrowserKey> { Set(browsers.keys) }
    func browser(for key: LeoAgentBrowserKey) -> (any LeoAgentBrowserPaneSource)? { browsers[key] }

    @discardableResult
    func open(_ key: LeoAgentBrowserKey) -> FakePaneSource {
        if let existing = browsers[key] { return existing }
        let source = FakePaneSource()
        browsers[key] = source
        handlers.values.forEach { $0(.opened(key)) }
        return source
    }

    func closeBrowser(for key: LeoAgentBrowserKey) {
        closeRequests.append(key)
        remove(key)
    }

    /// The agent stopped: the browser goes without a close request.
    func remove(_ key: LeoAgentBrowserKey) {
        guard browsers.removeValue(forKey: key) != nil else { return }
        handlers.values.forEach { $0(.closed(key)) }
    }

    func observe(_ handler: @escaping @MainActor (LeoAgentBrowserPresenceChange) -> Void) -> () -> Void {
        let id = UUID()
        handlers[id] = handler
        return { [weak self] in self?.handlers[id] = nil }
    }
}

/// Lets what the main queue already holds run -- the panes refresh there
/// after a model change -- without waiting on a clock.
@MainActor func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
