import Combine
import Foundation
import LeoKit

/// What the browser pane's toolbar, tab strip and handoff banner show and
/// do, apart from drawing it. Reads one `LeoAgentBrowserPaneSource`; every
/// action the user takes through it is user input, which takes control from
/// the agent (a handoff stays a handoff: it is answered with Done or Decline).
@MainActor final class LeoAgentBrowserPaneModel: ObservableObject {
    struct Pill: Equatable {
        let title: String
        let symbol: String
        let isAgentDriving: Bool
        /// Whether Give back applies: only after the user took over, not during a handoff.
        let canGiveBack: Bool
    }

    struct TabItem: Equatable {
        let id: Int
        let title: String
        let isActive: Bool
    }

    struct Handoff: Equatable {
        let requestID: String
        let message: String
    }

    /// The download strip's one line (B-404).
    struct DownloadStrip: Equatable {
        enum Kind: Equatable {
            case downloading, saving, finished, failed
        }

        let id: Int
        let kind: Kind
        let text: String
        /// 0...1 while downloading with a known size.
        let progress: Double?
    }

    /// Runs `action` after `delay` on the main actor.
    typealias Schedule = @MainActor (_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> Void

    /// How long a saved file's line stays; a failure stays until dismissed.
    static let finishedDownloadDuration: Duration = .seconds(5)

    /// How long the dialog bar says the agent answered.
    static let dialogHandledDuration: Duration = .seconds(4)

    static let blankTabTitle = "New Tab"
    static let invalidURLMessage = "Enter a web address starting with http:// or https://"

    let source: any LeoAgentBrowserPaneSource
    @Published private(set) var control: LeoBrowserControl
    /// The active tab's address, in the agent's (remote) terms.
    @Published private(set) var urlText = ""
    /// Why the last address entered wasn't loaded; cleared by the next valid one.
    @Published private(set) var urlError: String?
    @Published private(set) var tabItems: [TabItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// The active tab's permission request waiting on the user (B-410).
    @Published private(set) var permission: LeoBrowserPermissionPrompt?
    /// The active tab's open JavaScript dialog (B-412).
    @Published private(set) var dialog: LeoBrowserDialogPrompt?
    /// "alfred answered: OK" for a moment after the agent answered the
    /// dialog the active tab showed.
    @Published private(set) var dialogHandledLine: String?
    /// The latest download, or File-menu save (B-406), the user hasn't
    /// dismissed, or nil.
    @Published private(set) var downloadStrip: DownloadStrip?
    /// Says each download's outcome once, for VoiceOver.
    var onAnnouncement: (@MainActor (String) -> Void)?
    private let schedule: Schedule
    private var dismissedDownloads: Set<Int> = []
    /// Saved files whose line has had its time.
    private var expiredDownloads: Set<Int>
    private var announcedDownloads: Set<Int>
    /// The latest File-menu save, while its line shows.
    private var capture: Capture?
    /// Saves count down from -1, so they never share an id with a download.
    private var nextCaptureID = -1
    /// Tells the latest handled line from an earlier one whose time is up.
    private var handledLineID = 0
    private var stoppers: [() -> Void] = []
    /// The address the user sent, shown in the bar until that load commits (B-426).
    private var provisional: ProvisionalAddress?
    private var submissionCount = 0

    /// A typed address awaiting its page, as Safari keeps it in the bar. It
    /// ends when the page commits (the address or the tab changes) or the
    /// load ends without committing, so the bar never invents a state the
    /// page didn't report.
    private struct ProvisionalAddress {
        let id: Int
        let text: String
        /// The committed address and tab when it was sent.
        let baseURL: URL?
        let tabID: Int?
        /// Whether the source was loading at the last look. A load only counts
        /// as this address's once it starts after the send (false to true), so
        /// the previous page finishing can't end it.
        var wasLoading: Bool
        var sawLoading = false
    }

    /// A File-menu save's line. It shows until a download newer than the
    /// save starts, it is dismissed, or (once saved) its time is up.
    private struct Capture {
        let strip: DownloadStrip
        /// The newest download when the save began.
        let newestDownloadAtStart: Int
    }

    /// Downloads that ended before the pane opened are not announced, and
    /// only their failures show.
    init(source: any LeoAgentBrowserPaneSource, schedule: @escaping Schedule = LeoAgentBrowserPaneModel.scheduleOnMain) {
        self.source = source
        self.schedule = schedule
        control = source.control.state
        let entries = source.downloads.entries
        expiredDownloads = Set(entries.filter { Self.kind(of: $0.state) == .finished }.map(\.id))
        announcedDownloads = Set(entries.filter { [.finished, .failed].contains(Self.kind(of: $0.state)) }.map(\.id))
        refresh()
        refreshDownloads()
        stoppers = [
            source.observe { [weak self] in self?.refresh() },
            source.control.observe { [weak self] state in self?.control = state },
            source.downloads.observe { [weak self] in self?.refreshDownloads() },
            source.tabs.dialogs.observe { [weak self] in self?.dialogEvent($0) },
        ]
    }

    static let scheduleOnMain: Schedule = { delay, action in
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            action()
        }
    }

    deinit {
        stoppers.forEach { $0() }
    }

    var pill: Pill {
        switch control {
        case .agent: Pill(title: "Agent driving", symbol: "sparkles", isAgentDriving: true, canGiveBack: false)
        case .user: Pill(title: "You have control", symbol: "person.fill", isAgentDriving: false, canGiveBack: true)
        case .handoff: Pill(title: "You have control", symbol: "person.fill", isAgentDriving: false, canGiveBack: false)
        }
    }

    var handoff: Handoff? {
        control.pendingHandoff.map { Handoff(requestID: $0.requestID, message: $0.message) }
    }

    // MARK: - Actions

    func pillClicked() { source.control.send(.pill) }
    func giveBack() { source.control.send(.giveBack) }

    func done() {
        guard let handoff else { return }
        source.control.send(.done(requestID: handoff.requestID))
    }

    func decline() {
        guard let handoff else { return }
        source.control.send(.decline(requestID: handoff.requestID))
    }

    /// Allow or Don't Allow on the permission bar. Answering for the page
    /// is not driving it: the agent keeps control.
    func answerPermission(allow: Bool) {
        guard let permission else { return }
        source.answerPermission(permission, allow: allow)
    }

    /// OK, Cancel, Stay on Page or Leave Page in the dialog bar. Answering
    /// for the page is not driving it: the agent keeps control.
    func answerDialog(accept: Bool, text: String?) {
        guard let dialog else { return }
        source.answerDialog(dialog, accept: accept, text: text)
    }

    /// What the dialog bar shows: the open dialog, else the agent's answer.
    var dialogBar: LeoBrowserDialogBar.Content? {
        dialog.map { .dialog($0) } ?? dialogHandledLine.map { .handled($0) }
    }

    /// The agent answered the dialog in the tab the user is looking at:
    /// say so for a moment. The user's own answers need no line.
    private func dialogEvent(_ event: LeoBrowserDialogDesk.Event) {
        guard case .answered(let answer) = event, answer.answerer == .agent,
              source.tabs.tabs.first(where: \.isActive)?.id == answer.dialog.tab else { return }
        handledLineID += 1
        let id = handledLineID
        dialogHandledLine = LeoBrowserDialogText.handledLine(agent: source.key.agent, answer: answer)
        schedule(Self.dialogHandledDuration) { [weak self] in
            guard let self, handledLineID == id else { return }
            dialogHandledLine = nil
        }
    }

    /// The strip's close button: hides this download's line (the download
    /// itself carries on), or the save's.
    func dismissDownload() {
        guard let id = downloadStrip?.id else { return }
        if id == capture?.strip.id { capture = nil } else { dismissedDownloads.insert(id) }
        refreshDownloads()
    }

    // MARK: - File-menu saves (B-406)

    /// A File-menu save started; its line says so until `finishCapture`.
    /// `name` is the file name asked for (the saved one may be numbered).
    func beginCapture(name: String) -> Int {
        let id = nextCaptureID
        nextCaptureID -= 1
        show(DownloadStrip(id: id, kind: .saving, text: "Saving “\(name)”…", progress: nil))
        return id
    }

    /// The save ended: its line names the file as saved and goes after a
    /// while, or says why nothing was saved and stays. Said once for VoiceOver.
    func finishCapture(_ id: Int, name: String, outcome: Result<LeoBrowserSavedDownload, LeoBrowserError>) {
        // Only the newest save reports; a dismissed "Saving…" line still
        // gets its outcome.
        guard id == nextCaptureID + 1 else { return }
        let strip: DownloadStrip
        switch outcome {
        case .success(let saved):
            strip = DownloadStrip(id: id, kind: .finished, text: "Saved “\(saved.name)” to \(Self.place(of: saved))", progress: nil)
            schedule(Self.finishedDownloadDuration) { [weak self] in
                guard self?.capture?.strip.id == id else { return }
                self?.capture = nil
                self?.refreshDownloads()
            }
        case .failure(let error):
            let reason = error.code == .saveFailed ? error.message : "\(error.message) Nothing was saved."
            strip = DownloadStrip(id: id, kind: .failed, text: "Couldn’t save “\(name)”. \(reason)", progress: nil)
        }
        show(strip)
        onAnnouncement?(strip.text)
    }

    private func show(_ strip: DownloadStrip) {
        capture = Capture(strip: strip, newestDownloadAtStart: capture?.newestDownloadAtStart ?? (source.downloads.entries.map(\.id).max() ?? 0))
        refreshDownloads()
    }

    /// The saved file's folder, workspace-relative ("reports/q3/"), or "the workspace".
    private static func place(of saved: LeoBrowserSavedDownload) -> String {
        let folder = (saved.workspacePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? "the workspace" : folder + "/"
    }

    func goBack() { act { source.goBack() } }
    func goForward() { act { source.goForward() } }
    func reload() { act { source.reload() } }
    func newTab() { act { source.openBlankTab() } }

    /// ⌘⇧T. False (and no takeover) when there is nothing to reopen.
    @discardableResult
    func reopenClosedTab() -> Bool {
        guard source.canReopenClosedTab else { return false }
        act { _ = source.reopenClosedTab() }
        return true
    }

    func history(_ direction: LeoBrowserHistoryDirection) -> [LeoBrowserHistoryEntry] {
        source.history(direction)
    }

    /// A pick from a history menu. False (and no takeover) when the history
    /// has changed since the menu was built.
    @discardableResult
    func goToHistory(_ entry: LeoBrowserHistoryEntry) -> Bool {
        guard source.history(entry.direction).contains(entry) else { return false }
        act { _ = source.goToHistory(entry) }
        return true
    }
    func selectTab(id: Int) { act { source.tabs.selectTab(id) } }
    func closeTab(id: Int) { act { source.tabs.closeTab(id) } }

    /// Enter in the address bar.
    func submitURL(_ text: String) {
        guard let url = Self.url(fromInput: text) else {
            urlError = Self.invalidURLMessage
            return
        }
        urlError = nil
        submissionCount += 1
        let id = submissionCount
        provisional = ProvisionalAddress(id: id, text: url.absoluteString, baseURL: source.activeRemoteURL, tabID: activeTabID, wasLoading: source.isLoading)
        act { source.navigate(to: url) { [weak self] in self?.navigationFailed(id) } }
        refresh()
    }

    /// The source couldn't start submission `id`: no load will follow, so the
    /// bar goes back to the page's address (D-928), unless a newer address took over.
    private func navigationFailed(_ id: Int) {
        guard provisional?.id == id else { return }
        provisional = nil
        refresh()
    }

    private var activeTabID: Int? { source.tabs.tabs.first(where: \.isActive)?.id }

    /// The address to show: the sent one while its load is pending, else the page's.
    private func resolvedURLText() -> String {
        let remote = source.activeRemoteURL
        if var pending = provisional {
            let committed = remote != pending.baseURL || activeTabID != pending.tabID
            pending.sawLoading = pending.sawLoading || (source.isLoading && !pending.wasLoading)
            pending.wasLoading = source.isLoading
            let ended = pending.sawLoading && !source.isLoading
            provisional = committed || ended ? nil : pending
        }
        return provisional?.text ?? remote?.absoluteString ?? ""
    }

    private func act(_ action: () -> Void) {
        source.control.send(.userInput)
        action()
    }

    // MARK: - Reading the source

    private func refresh() {
        set(\.urlText, resolvedURLText())
        set(\.tabItems, source.tabs.tabs.map {
            TabItem(id: $0.id, title: $0.title.isEmpty ? Self.blankTabTitle : $0.title, isActive: $0.isActive)
        })
        set(\.isLoading, source.isLoading)
        set(\.canGoBack, source.canGoBack)
        set(\.canGoForward, source.canGoForward)
        set(\.permission, source.pendingPermission)
        set(\.dialog, source.pendingDialog)
    }

    private func refreshDownloads() {
        let entries = source.downloads.entries
        for entry in entries where !announcedDownloads.contains(entry.id) {
            let kind = Self.kind(of: entry.state)
            guard kind == .finished || kind == .failed else { continue }
            announcedDownloads.insert(entry.id)
            onAnnouncement?(Self.strip(for: entry).text)
            if kind == .finished {
                schedule(Self.finishedDownloadDuration) { [weak self] in self?.expire(entry.id) }
            }
        }
        let visible = entries.first { !dismissedDownloads.contains($0.id) && !expiredDownloads.contains($0.id) }
        if let capture, entries.allSatisfy({ $0.id <= capture.newestDownloadAtStart }) {
            set(\.downloadStrip, capture.strip)
        } else {
            capture = nil
            set(\.downloadStrip, visible.map(Self.strip(for:)))
        }
    }

    private func expire(_ id: Int) {
        expiredDownloads.insert(id)
        refreshDownloads()
    }

    private static func kind(of state: LeoBrowserDownload.State) -> DownloadStrip.Kind {
        switch state {
        case .downloading: .downloading
        case .saving: .saving
        case .finished: .finished
        case .failed: .failed
        }
    }

    static func strip(for download: LeoBrowserDownload) -> DownloadStrip {
        let folder = LeoBrowserDownloadSaver.folderName + "/"
        switch download.state {
        case let .downloading(received, expected):
            let fraction = expected.flatMap { $0 > 0 ? min(1, Double(received) / Double($0)) : nil }
            let percent = fraction.map { " \(Int(($0 * 100).rounded(.down)))%" } ?? ""
            return DownloadStrip(id: download.id, kind: .downloading, text: "Downloading “\(download.name)”…\(percent)", progress: fraction)
        case .saving:
            return DownloadStrip(id: download.id, kind: .saving, text: "Saving “\(download.name)” to \(folder)…", progress: nil)
        case .finished(let saved):
            return DownloadStrip(id: download.id, kind: .finished, text: "Saved “\(saved.name)” to \(folder)", progress: nil)
        case .failed(let message):
            return DownloadStrip(id: download.id, kind: .failed, text: "Couldn’t download “\(download.name)”. \(message)", progress: nil)
        }
    }

    /// Assigns only a change, so an unrelated source change doesn't redraw the
    /// pane. (Passing a `@Published` property `inout` would publish regardless.)
    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<LeoAgentBrowserPaneModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: - Address bar text

    private static let schemePrefix = #"^[A-Za-z][A-Za-z0-9+.\-]*:"#
    private static let hostAndPort = #"^[A-Za-z0-9.\-]+:\d{1,5}(?:[/?#].*)?$"#
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]"]

    /// The page an address-bar entry names: a full URL, or a bare host
    /// (`example.com`, `localhost:3000`) given `https` -- `http` for loopback,
    /// where dev servers rarely have a certificate. nil for text the browser
    /// would not load (other schemes, no host, blanks).
    static func url(fromInput input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let isBareHostAndPort = text.range(of: hostAndPort, options: .regularExpression) != nil
        let hasScheme = text.range(of: schemePrefix, options: .regularExpression) != nil
        let candidate = hasScheme && !isBareHostAndPort ? text : "\(defaultScheme(for: text))://\(text)"
        return try? LeoBrowserURLPolicy.validate(candidate)
    }

    private static func defaultScheme(for text: String) -> String {
        let host = text.range(of: #"^(\[[^\]]*\]|[^:/?#]*)"#, options: .regularExpression).map { String(text[$0]) } ?? ""
        return loopbackHosts.contains(host.lowercased()) ? "http" : "https"
    }
}
