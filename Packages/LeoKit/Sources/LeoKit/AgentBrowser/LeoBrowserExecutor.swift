import Foundation

/// Runs browser tool calls against an agent browser: decodes the command, checks
/// who has control, runs it on the right tab, and shapes the result the agent
/// sees. Knows nothing of WebKit; it drives `LeoBrowserTabs` / `LeoBrowserPage`.
///
/// Operations run one at a time in arrival order. `browser_handoff` is the
/// exception: it waits on the user, so it neither queues behind a running
/// operation nor blocks one. So is `browser_dialog` (B-412): the call it
/// would queue behind may be the one its dialog paused. A cancelled call
/// (the daemon's tool timeout) frees the queue even if the page never
/// answers, and so does a JavaScript dialog opening while a call runs: the
/// call returns at once, saying so, and its own late result is dropped.
@MainActor
public final class LeoBrowserExecutor {
    public typealias Sleeper = @MainActor (Duration) async throws -> Void

    private let tabs: any LeoBrowserTabs
    private let urlMapping: any LeoBrowserURLMapping
    private let control: LeoBrowserControlModel
    private let sleep: Sleeper
    private let uploads: LeoBrowserUploadReader
    private let gate = LeoBrowserSerialGate()

    public init(
        tabs: any LeoBrowserTabs, urlMapping: any LeoBrowserURLMapping, control: LeoBrowserControlModel,
        uploads: LeoBrowserUploadReader = .noWorkspace,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.tabs = tabs
        self.uploads = uploads
        self.urlMapping = urlMapping
        self.control = control
        self.sleep = sleep
    }

    /// Never throws: every failure is a `.failure` outcome with a code from the
    /// contract (plus `cancelled` when the daemon cancels the call).
    public func execute(tool: String, args: LeoJSONValue, requestID: String) async -> LeoClientToolOutcome {
        withDialogNotes(await outcome(tool: tool, args: args, requestID: requestID))
    }

    private func outcome(tool: String, args: LeoJSONValue, requestID: String) async -> LeoClientToolOutcome {
        do {
            let command = try LeoBrowserCommand(tool: tool, args: args)
            switch command.action {
            case .handoff(let message):
                return try await handoff(requestID: requestID, message: message)
            case .dialog(let accept, let text):
                return .success(try answerDialog(inTab: command.tab, accept: accept, text: text))
            default:
                break
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

    /// Checks control and the tab's dialog, then runs the command until it
    /// finishes or any tab opens a dialog.
    private func perform(_ command: LeoBrowserCommand) async throws -> [LeoClientToolContent] {
        if command.action.changesPage, !control.state.allowsAgentActions { throw LeoBrowserError.userHasControl }
        if command.action.needsPage, let dialog = tabID(command.tab).flatMap(dialogs.dialog(inTab:)) {
            dialogs.markTold(dialog.id)
            throw LeoBrowserError(.dialogOpen, LeoBrowserDialogText.openLine(dialog, origin: remoteOrigin(dialog.site)))
        }
        return try await untilADialogOpens { try await self.run(command) }
    }

    private func run(_ command: LeoBrowserCommand) async throws -> [LeoClientToolContent] {
        switch command.action {
        case .tabs:
            let list = tabs.tabs
            list.compactMap { dialogs.dialog(inTab: $0.id)?.id }.forEach(dialogs.markTold)
            return [json(.array(list.map(tabEntry)))]
        case .downloads:
            return [json(.array(tabs.downloads.map(downloadEntry)))]
        case .tabNew(let url, let userAgent):
            return try await openTab(url: url, userAgent: userAgent)
        case .tabSelect(let tab):
            try requireTab(tab)
            tabs.selectTab(tab)
        case .tabClose(let tab):
            try requireTab(tab)
            tabs.closeTab(tab)
        case .wait(.milliseconds(let milliseconds)):
            try await sleep(.milliseconds(milliseconds))
        case .handoff, .dialog:
            throw LeoBrowserError.invalidArgs("\(command.action) cannot be queued")
        case .navigate(let url) where command.tab == nil && tabs.tabs.isEmpty:
            return try await navigateInNewTab(url: url)
        default:
            return try await perform(command.action, on: try page(command.tab), tab: command.tab)
        }
        return [Self.ok]
    }

    /// `browser_navigate` with no tab open: open one at the URL instead of
    /// making the agent call `browser_tab_new` first.
    private func navigateInNewTab(url: String) async throws -> [LeoClientToolContent] {
        let opened = try await openTab(url: url, userAgent: nil)
        guard let page = tabs.page(forTab: nil) else { return opened }
        return [report(page)]
    }

    /// `tab` is the command's own (nil for the active tab).
    private func perform(_ action: LeoBrowserAction, on page: any LeoBrowserPage, tab: Int?) async throws -> [LeoClientToolContent] {
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
            let text = try await page.snapshot()
            return [.text(waitingLine(forTab: tab).map { $0 + "\n" + text } ?? text)]
        case .click(let ref):
            try await page.click(ref: ref)
        case .type(let ref, let text, let submit):
            try await page.type(ref: ref, text: text, submit: submit)
        case .upload(let ref, let paths):
            return [try await upload(ref: ref, paths: paths, on: page)]
        case .press(let combo):
            try await page.press(combo)
        case .screenshot(let fullPage, nil):
            return [.image(data: try await page.screenshot(fullPage: fullPage).base64EncodedString(), mimeType: "image/png")]
        case .screenshot(let fullPage, let path?):
            return [try await save(try await page.screenshot(fullPage: fullPage), kind: .png, path: path, of: page)]
        case .pdf(let path):
            return [try await save(try await page.pdf(), kind: .pdf, path: path, of: page)]
        case .wait(.text(let text)):
            try await page.waitForText(text, timeoutMilliseconds: LeoBrowserCommand.maximumWaitMilliseconds)
        case .eval(let js):
            return [.text(try await page.evaluate(js))]
        case .console(let since):
            return [consoleReport(page.consoleMessages(since: since))]
        case .setUserAgent(let userAgent):
            page.setUserAgent(userAgent)
        case .wait(.milliseconds), .tabs, .tabNew, .tabSelect, .tabClose, .downloads, .handoff, .dialog:
            throw LeoBrowserError.invalidArgs("\(action) is not a page action")
        }
        return [Self.ok]
    }

    /// Saves a capture of `page` and reports where it landed, named as
    /// saved (numbered after a clash). The default name comes from the
    /// title, else the host in remote terms.
    private func save(_ data: Data, kind: LeoBrowserCaptureKind, path: String?, of page: any LeoBrowserPage) async throws -> LeoClientToolContent {
        let host = page.url.map(urlMapping.toRemote)?.host()
        let defaultName = LeoBrowserCapturePath.defaultName(title: page.title, host: host, kind: kind)
        let saved: LeoBrowserSavedDownload
        do {
            saved = try await tabs.saveCapture(data, kind: kind, path: path, defaultName: defaultName)
        } catch let error as LeoBrowserError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LeoBrowserError(.saveFailed, error.localizedDescription)
        }
        return json(.object([
            "path": .string(saved.path), "workspace_path": .string(saved.workspacePath), "size": .int(Int(clamping: saved.size)),
        ]))
    }

    private func openTab(url: String?, userAgent: String?) async throws -> [LeoClientToolContent] {
        let remote = try url.map(LeoBrowserURLPolicy.validate)
        guard tabs.tabs.count < LeoBrowserLimits.maximumTabs else { throw LeoBrowserError.tabLimit(LeoBrowserLimits.maximumTabs) }
        var local = Self.blank
        if let remote { local = try await urlMapping.toLocal(remote) }
        let id = try await tabs.openTab(url: local, userAgent: userAgent)
        return [json(.object(["tab": .int(id)]))]
    }

    /// Checks the input before reading a byte; reading can be slow over SFTP,
    /// so control is checked again before the files are set.
    private func upload(ref: String, paths: [String], on page: any LeoBrowserPage) async throws -> LeoClientToolContent {
        let input = try await page.fileInput(ref: ref)
        guard paths.count == 1 || input.allowsMultiple else {
            throw LeoBrowserError.invalidArgs("ref \(ref) is a file input that takes one file; pass one path")
        }
        let files = try await uploads.read(paths)
        guard control.state.allowsAgentActions else { throw LeoBrowserError.userHasControl }
        try await page.setFiles(ref: ref, files: files)
        return json(.object(["files": .array(files.map { file in
            .object(["name": .string(file.name), "size": .int(file.data.count), "workspace_path": .string(file.workspacePath)])
        })]))
    }

    private func handoff(requestID: String, message: String) async throws -> LeoClientToolOutcome {
        switch await control.requestHandoff(requestID: requestID, message: message) {
        case .done?: return .success([.text("done")])
        case .declined?: return .success([.text("declined")])
        case nil: return .failure(Self.cancelledError)
        }
    }

    // MARK: - Dialogs (B-412)

    private var dialogs: LeoBrowserDialogDesk { tabs.dialogs }

    /// `browser_dialog`: answers at once, never queued, since the call it
    /// would wait behind may be one its dialog paused. Whoever answers
    /// first wins; a later answer hears how it went. Only a dialog the agent
    /// was shown is answered: an open one it hasn't seen is described instead.
    private func answerDialog(inTab tab: Int?, accept: Bool, text: String?) throws -> [LeoClientToolContent] {
        guard control.state.allowsAgentActions else { throw LeoBrowserError.userHasControl }
        guard let id = tabID(tab) else { throw LeoBrowserError(.noSuchTab, "The browser has no tabs") }
        try requireTab(id)
        let open = dialogs.dialog(inTab: id)
        if let open, !dialogs.wasTold(open.id) {
            // The page opened it after the one the agent saw was answered:
            // describe it, leave it open, and let the agent decide again.
            dialogs.markTold(open.id)
            throw LeoBrowserError(.dialogOpen, LeoBrowserDialogText.unseenLine(open, origin: remoteOrigin(open.site)))
        }
        if text != nil, let open, open.kind != .prompt {
            throw LeoBrowserError.invalidArgs("text answers a prompt; tab \(id) has a \(LeoBrowserDialogText.name(open.kind)) open. Call again without text")
        }
        switch dialogs.answer(inTab: id, dialog: open?.id, accept: accept, text: text, by: .agent) {
        case .answered:
            return [Self.ok]
        case .alreadyHandled(let answer):
            throw LeoBrowserError(.dialogHandled, LeoBrowserDialogText.handledMessage(answer))
        case .noDialog:
            throw LeoBrowserError(.noDialog, LeoBrowserDialogText.noDialog(tab: id, elsewhere: dialogs.dialogs))
        }
    }

    /// Runs `work` until it finishes or any tab opens a dialog, whichever
    /// comes first. A dialog pauses its page (and every page sharing its
    /// process), so `work` may not finish until someone answers it: the
    /// call reports the dialog instead, and `work`'s late result is dropped.
    private func untilADialogOpens(_ work: @escaping @MainActor () async throws -> [LeoClientToolContent]) async throws -> [LeoClientToolContent] {
        let outcome = LeoOnce<[LeoClientToolContent]>()
        let stopObserving = dialogs.observe { [weak self] event in
            guard case .opened(let dialog) = event, !outcome.isSettled, let self else { return }
            dialogs.markTold(dialog.id)
            outcome.resume(with: .success([.text(LeoBrowserDialogText.openedLine(dialog, origin: remoteOrigin(dialog.site)))]))
        }
        defer { stopObserving() }
        let task = Task { @MainActor in
            do { outcome.resume(with: .success(try await work())) } catch { outcome.resume(with: .failure(error)) }
        }
        return try await withTaskCancellationHandler {
            try await outcome.value()
        } onCancel: {
            task.cancel()
            Task { @MainActor in outcome.resume(with: .failure(CancellationError())) }
        }
    }

    /// Adds what the agent hasn't heard yet: the user's answers to dialogs
    /// it was shown. Not to a cancelled call, which nobody reads.
    private func withDialogNotes(_ outcome: LeoClientToolOutcome) -> LeoClientToolOutcome {
        if case .failure(let error) = outcome, error == Self.cancelledError { return outcome }
        let notes = dialogs.takeNotes().map(LeoBrowserDialogText.handledNote)
        guard !notes.isEmpty else { return outcome }
        switch outcome {
        case .success(let content):
            return .success(content + notes.map(LeoClientToolContent.text))
        case .failure(let error):
            return .failure(LeoClientToolError(code: error.code, message: ([error.message] + notes).joined(separator: "\n")))
        }
    }

    private func dialogEntry(_ dialog: LeoBrowserDialog) -> LeoJSONValue {
        var entry: [String: LeoJSONValue] = [
            "kind": .string(dialog.kind.rawValue), "message": .string(LeoBrowserDialogText.capped(LeoBrowserDialogText.message(of: dialog))),
            "site": .string(remoteOrigin(dialog.site)),
        ]
        if let defaultText = dialog.defaultText { entry["default_text"] = .string(LeoBrowserDialogText.capped(defaultText)) }
        return .object(entry)
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
        var entry: [String: LeoJSONValue] = [
            "id": .int(tab.id), "url": .string(remoteString(tab.url)), "title": .string(tab.title), "active": .bool(tab.isActive),
        ]
        if let waiting = tab.waitingPermission {
            entry["waiting_on_user"] = .object(["permission": .string(waiting.kind.rawValue), "site": .string(remoteOrigin(waiting.site))])
        }
        if let dialog = dialogs.dialog(inTab: tab.id) { entry["dialog"] = dialogEntry(dialog) }
        return .object(entry)
    }

    /// `tab`, or the active tab's id when nil; nil with no tabs.
    private func tabID(_ tab: Int?) -> Int? {
        tab ?? tabs.tabs.first(where: \.isActive)?.id
    }

    /// A site's origin in remote terms (a forwarded local port maps back).
    private func remoteOrigin(_ site: LeoBrowserSite) -> String {
        site.url.map(urlMapping.toRemote).flatMap(LeoBrowserSite.init(url:))?.origin ?? site.origin
    }

    /// What a snapshot of `tab` (the active tab when nil) leads with while
    /// its page waits on the user.
    private func waitingLine(forTab tab: Int?) -> String? {
        let info = tabs.tabs.first { tab == nil ? $0.isActive : $0.id == tab }
        guard let waiting = info?.waitingPermission else { return nil }
        return LeoBrowserPermissionText.waitingLine(kind: waiting.kind, origin: remoteOrigin(waiting.site))
    }

    /// A finished download is named as saved (numbered after a clash).
    private func downloadEntry(_ download: LeoBrowserDownload) -> LeoJSONValue {
        var entry: [String: LeoJSONValue] = ["id": .int(download.id), "name": .string(download.name), "url": .string(remoteString(download.sourceURL))]
        switch download.state {
        case .downloading(let received, let expected):
            entry["state"] = .string("downloading")
            entry["received_bytes"] = .int(Int(clamping: received))
            if let expected { entry["expected_bytes"] = .int(Int(clamping: expected)) }
        case .saving:
            entry["state"] = .string("saving")
        case .finished(let saved):
            entry["state"] = .string("finished")
            entry["name"] = .string(saved.name)
            entry["path"] = .string(saved.path)
            entry["workspace_path"] = .string(saved.workspacePath)
            entry["size"] = .int(Int(clamping: saved.size))
        case .failed(let message):
            entry["state"] = .string("failed")
            entry["error"] = .string(message)
        }
        return .object(entry)
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
        return .text((try? encoder.encode(value)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "null")
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
