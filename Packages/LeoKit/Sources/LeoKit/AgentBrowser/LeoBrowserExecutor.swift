import Foundation

/// Runs browser tool calls against an agent browser: decodes the command, checks
/// who has control, runs it on the right tab, and shapes the result the agent
/// sees. Knows nothing of WebKit; it drives `LeoBrowserTabs` / `LeoBrowserPage`.
///
/// Operations run one at a time in arrival order. `browser_handoff` is the
/// exception: it waits on the user, so it neither queues behind a running
/// operation nor blocks one.
@MainActor
public final class LeoBrowserExecutor {
    public typealias Sleeper = @MainActor (Duration) async throws -> Void

    private let tabs: any LeoBrowserTabs
    private let urlMapping: any LeoBrowserURLMapping
    private let control: LeoBrowserControlModel
    private let sleep: Sleeper
    private let gate = LeoBrowserSerialGate()

    public init(
        tabs: any LeoBrowserTabs, urlMapping: any LeoBrowserURLMapping, control: LeoBrowserControlModel,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.tabs = tabs
        self.urlMapping = urlMapping
        self.control = control
        self.sleep = sleep
    }

    /// Never throws: every failure is a `.failure` outcome with a code from the
    /// contract (plus `cancelled` when the daemon cancels the call).
    public func execute(tool: String, args: LeoJSONValue, requestID: String) async -> LeoClientToolOutcome {
        do {
            let command = try LeoBrowserCommand(tool: tool, args: args)
            if case .handoff(let message) = command.action {
                return try await handoff(requestID: requestID, message: message)
            }
            let content = try await gate.run {
                do { return try await self.perform(command) } catch { throw Self.classify(error, for: command.action) }
            }
            return .success(content)
        } catch let error as LeoBrowserError {
            return .failure(error.clientToolError)
        } catch {
            return .failure(Self.cancelledError)
        }
    }

    private static let cancelledError = LeoClientToolError(code: "cancelled", message: "The request was cancelled")

    // MARK: - Operations

    private func perform(_ command: LeoBrowserCommand) async throws -> [LeoClientToolContent] {
        if command.action.changesPage, !control.state.allowsAgentActions { throw LeoBrowserError.userHasControl }
        switch command.action {
        case .tabs:
            return [json(.array(tabs.tabs.map(tabEntry)))]
        case .tabNew(let url):
            return try await openTab(url: url)
        case .tabSelect(let tab):
            try requireTab(tab)
            tabs.selectTab(tab)
        case .tabClose(let tab):
            try requireTab(tab)
            tabs.closeTab(tab)
        case .wait(.milliseconds(let milliseconds)):
            try await sleep(.milliseconds(milliseconds))
        case .handoff:
            throw LeoBrowserError.invalidArgs("browser_handoff cannot be queued")
        default:
            return try await perform(command.action, on: try page(command.tab))
        }
        return [Self.ok]
    }

    private func perform(_ action: LeoBrowserAction, on page: any LeoBrowserPage) async throws -> [LeoClientToolContent] {
        switch action {
        case .navigate(let url):
            try await page.load(try await urlMapping.toLocal(try LeoBrowserURLPolicy.validate(url)))
            return [report(page)]
        case .back:
            try await page.goBack()
            return [report(page)]
        case .forward:
            try await page.goForward()
            return [report(page)]
        case .reload:
            try await page.reload()
            return [report(page)]
        case .snapshot:
            return [.text(try await page.snapshot())]
        case .click(let ref):
            try await page.click(ref: ref)
        case .type(let ref, let text, let submit):
            try await page.type(ref: ref, text: text, submit: submit)
        case .press(let combo):
            try await page.press(combo)
        case .screenshot(let fullPage):
            return [.image(data: try await page.screenshot(fullPage: fullPage).base64EncodedString(), mimeType: "image/png")]
        case .wait(.text(let text)):
            try await page.waitForText(text, timeoutMilliseconds: LeoBrowserCommand.maximumWaitMilliseconds)
        case .eval(let js):
            return [.text(try await page.evaluate(js))]
        case .console(let since):
            return [consoleReport(page.consoleMessages(since: since))]
        case .wait(.milliseconds), .tabs, .tabNew, .tabSelect, .tabClose, .handoff:
            throw LeoBrowserError.invalidArgs("\(action) is not a page action")
        }
        return [Self.ok]
    }

    private func openTab(url: String?) async throws -> [LeoClientToolContent] {
        let remote = try url.map(LeoBrowserURLPolicy.validate)
        guard tabs.tabs.count < LeoBrowserLimits.maximumTabs else { throw LeoBrowserError.tabLimit(LeoBrowserLimits.maximumTabs) }
        var local = Self.blank
        if let remote { local = try await urlMapping.toLocal(remote) }
        let id = try await tabs.openTab(url: local)
        return [json(.object(["tab": .int(id)]))]
    }

    private func handoff(requestID: String, message: String) async throws -> LeoClientToolOutcome {
        switch await control.requestHandoff(requestID: requestID, message: message) {
        case .done?: return .success([.text("done")])
        case .declined?: return .success([.text("declined")])
        case nil: return .failure(Self.cancelledError)
        }
    }

    // MARK: - Helpers

    private static let ok = LeoClientToolContent.text("ok")
    private static let blank = URL(string: "about:blank")!

    private func page(_ tab: Int?) throws -> any LeoBrowserPage {
        guard let page = tabs.page(forTab: tab) else {
            if let tab { throw LeoBrowserError.noSuchTab(tab) }
            throw LeoBrowserError(.noSuchTab, "The browser has no tabs; call browser_tab_new")
        }
        return page
    }

    private func requireTab(_ tab: Int) throws {
        guard tabs.tabs.contains(where: { $0.id == tab }) else { throw LeoBrowserError.noSuchTab(tab) }
    }

    private func remoteString(_ url: URL?) -> String { url.map { urlMapping.toRemote($0).absoluteString } ?? "" }

    private func report(_ page: any LeoBrowserPage) -> LeoClientToolContent {
        json(.object(["url": .string(remoteString(page.url)), "title": .string(page.title)]))
    }

    private func tabEntry(_ tab: LeoBrowserTabInfo) -> LeoJSONValue {
        .object([
            "id": .int(tab.id), "url": .string(remoteString(tab.url)), "title": .string(tab.title), "active": .bool(tab.isActive),
        ])
    }

    private func consoleReport(_ batch: LeoBrowserConsoleBatch) -> LeoClientToolContent {
        json(.object([
            "cursor": .int(batch.cursor),
            "messages": .array(batch.entries.map { .object(["level": .string($0.level), "text": .string($0.text)]) }),
        ]))
    }

    private func json(_ value: LeoJSONValue) -> LeoClientToolContent {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .text((try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null")
    }

    /// Browser errors and cancellation pass through; anything else gets the
    /// generic code that fits the action.
    private static func classify(_ error: any Error, for action: LeoBrowserAction) -> any Error {
        if error is LeoBrowserError || error is CancellationError { return error }
        let code: LeoBrowserError.Code
        switch action {
        case .navigate, .back, .forward, .reload, .tabNew: code = .navigationFailed
        default: code = .jsError
        }
        return LeoBrowserError(code, error.localizedDescription)
    }
}
