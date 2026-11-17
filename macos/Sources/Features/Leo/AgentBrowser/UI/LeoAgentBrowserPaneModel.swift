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
    /// The latest download the user hasn't dismissed, or nil.
    @Published private(set) var downloadStrip: DownloadStrip?
    /// Says each download's outcome once, for VoiceOver.
    var onAnnouncement: (@MainActor (String) -> Void)?
    private let schedule: Schedule
    private var dismissedDownloads: Set<Int> = []
    /// Saved files whose line has had its time.
    private var expiredDownloads: Set<Int>
    private var announcedDownloads: Set<Int>
    private var stoppers: [() -> Void] = []

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

    /// The strip's close button: hides this download's line (the download
    /// itself carries on).
    func dismissDownload() {
        guard let id = downloadStrip?.id else { return }
        dismissedDownloads.insert(id)
        refreshDownloads()
    }

    func goBack() { act { source.goBack() } }
    func goForward() { act { source.goForward() } }
    func reload() { act { source.reload() } }
    func newTab() { act { source.openBlankTab() } }
    func selectTab(id: Int) { act { source.tabs.selectTab(id) } }
    func closeTab(id: Int) { act { source.tabs.closeTab(id) } }

    /// Enter in the address bar.
    func submitURL(_ text: String) {
        guard let url = Self.url(fromInput: text) else {
            urlError = Self.invalidURLMessage
            return
        }
        urlError = nil
        act { source.navigate(to: url) }
    }

    private func act(_ action: () -> Void) {
        source.control.send(.userInput)
        action()
    }

    // MARK: - Reading the source

    private func refresh() {
        set(\.urlText, source.activeRemoteURL?.absoluteString ?? "")
        set(\.tabItems, source.tabs.tabs.map {
            TabItem(id: $0.id, title: $0.title.isEmpty ? Self.blankTabTitle : $0.title, isActive: $0.isActive)
        })
        set(\.isLoading, source.isLoading)
        set(\.canGoBack, source.canGoBack)
        set(\.canGoForward, source.canGoForward)
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
        set(\.downloadStrip, visible.map(Self.strip(for:)))
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
