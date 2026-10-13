import Combine
import Foundation
import LeoKit

/// Leo Chat for the agent selected in the sidebar: its thread (paged,
/// merged by id with live `chat.*` events, reloaded after a reconnect or a
/// sequence gap), read marks while the pane is on screen, answers to `ask`
/// and `permission` prompts, attachment downloads, and a draft per agent
/// whose send keeps it on failure. Bound to the selected host's daemon by
/// `LeoRuntime`, like `LeoAgentControlModel`.
@MainActor final class LeoChatPaneModel: ObservableObject {
    static let pageSize = 50
    /// The longest voice note: ten minutes.
    static let maximumRecording: TimeInterval = 600
    /// Anything shorter was a click, not a recording.
    static let minimumRecording: TimeInterval = 0.5
    static let microphoneDeniedMessage = "Leo can't use the microphone. Allow it in System Settings ▸ Privacy & Security ▸ Microphone."

    typealias FileReader = @Sendable (LeoChatOutgoingFile) async throws -> LeoChatUpload

    @Published private(set) var agent: LeoAgentID?
    /// A prompt that is no longer open loses its ask draft.
    @Published private(set) var timeline = LeoChatTimeline() {
        didSet { dropSettledAskDrafts() }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingOlder = false
    @Published private(set) var loadError: String?
    /// Message ids with an answer in flight.
    @Published private(set) var answering: Set<String> = []
    /// The answer being put together per open `radio`, `checkboxes` or
    /// `text` ask, kept across thread switches until the prompt settles.
    @Published private(set) var askDrafts: [String: LeoChatAskDraft] = [:]
    /// Messages whose long text or task card is expanded.
    @Published private(set) var expanded: Set<String> = []
    @Published private(set) var drafts: [LeoAgentID: LeoChatComposerDraft] = [:]
    /// The send in flight per agent.
    @Published private(set) var sending: [LeoAgentID: LeoChatOutgoing] = [:]
    @Published private(set) var recording = LeoChatRecording.idle
    @Published private(set) var attachmentFiles: [String: LeoChatAttachmentFile] = [:]
    /// A failed send or answer, or a microphone problem.
    @Published private(set) var notice: String?

    private var client: any LeoChatClient
    private var host: LeoHostID
    private let recorder: any LeoChatVoiceRecording
    private let attachmentDirectory: URL
    private let maximumUploadBytes: Int
    private let readFile: FileReader
    /// Identifies the page request whose answer still counts.
    private var loadToken = 0
    private var visibleCount = 0
    private var lastRead: String?

    init(
        client: any LeoChatClient, host: LeoHostID, recorder: any LeoChatVoiceRecording, attachmentDirectory: URL,
        maximumUploadBytes: Int = LeoChatUpload.maximumBytes, readFile: @escaping FileReader = LeoChatPaneModel.readFromDisk
    ) {
        self.client = client
        self.host = host
        self.recorder = recorder
        self.attachmentDirectory = attachmentDirectory
        self.maximumUploadBytes = maximumUploadBytes
        self.readFile = readFile
    }

    /// The selected connection's daemon changed. Events and resyncs from
    /// any other host are ignored from now on.
    func updateClient(_ client: any LeoChatClient, host: LeoHostID) {
        self.client = client
        self.host = host
    }

    var isOnScreen: Bool { visibleCount > 0 }

    // MARK: Thread

    /// Shows `agent`'s thread (nil: none), loading its newest page.
    func show(_ agent: LeoAgentID?) async {
        guard agent != self.agent else { return }
        self.agent = agent
        timeline = LeoChatTimeline()
        expanded = []
        answering = []
        loadError = nil
        lastRead = nil
        isLoading = false
        isLoadingOlder = false
        loadToken += 1
        guard agent != nil else { return }
        await loadNewest()
    }

    /// A pane showing the thread appeared (true) or went away (false).
    func setOnScreen(_ isVisible: Bool) async {
        visibleCount = max(0, visibleCount + (isVisible ? 1 : -1))
        guard isVisible, let newest = timeline.newest else { return }
        await markRead(newest.id)
    }

    func receive(_ event: LeoChatEvent, host: LeoHostID) async {
        let message = event.message
        guard host == self.host, let agent, agent.host == host, timeline.admits(message, agent: agent.name) else { return }
        if case .updated = event, timeline.message(id: message.id) == nil { return }
        timeline.mergeLive(message, isFetching: isLoading || isLoadingOlder)
        guard case .message = event else { return }
        await markRead(message.id)
    }

    /// Events from `host` may have been lost (a reconnect or a sequence
    /// gap): the shown thread reloads its newest page and merges it by id.
    func resync(host: LeoHostID) async {
        guard host == self.host, let agent, agent.host == host else { return }
        await loadNewest()
    }

    func retry() async { await loadNewest() }

    func loadOlder() async {
        guard let agent, timeline.hasMore, !isLoading, !isLoadingOlder, let oldest = timeline.oldest else { return }
        isLoadingOlder = true
        let query = LeoChatPageQuery(before: oldest.id, limit: Self.pageSize, task: timeline.taskFilter)
        let result = await fetch(agent, query)
        guard let result else { return }
        isLoadingOlder = false
        apply(result)
    }

    func setTaskFilter(_ task: String?) async {
        guard agent != nil, task != timeline.taskFilter else { return }
        timeline = LeoChatTimeline(taskFilter: task, knownTasks: timeline.knownTasks)
        expanded = []
        await loadNewest()
    }

    func toggleExpanded(_ id: String) {
        if expanded.remove(id) == nil { expanded.insert(id) }
    }

    func dismissNotice() { notice = nil }

    func showNotice(_ text: String) { notice = text }

    private func loadNewest() async {
        guard let agent else { return }
        guard agent.host == host else {
            loadError = "\(agent.host.displayName) isn't connected."
            return
        }
        isLoading = true
        isLoadingOlder = false
        let result = await fetch(agent, LeoChatPageQuery(limit: Self.pageSize, task: timeline.taskFilter))
        guard let result else { return }
        isLoading = false
        apply(result)
        guard case .success = result, let newest = timeline.newest else { return }
        await markRead(newest.id)
    }

    /// One page request; nil when a newer request or another agent made
    /// its answer moot.
    private func fetch(_ agent: LeoAgentID, _ query: LeoChatPageQuery) async -> Result<LeoChatPage, any Error>? {
        loadToken += 1
        let token = loadToken
        timeline.beginFetch()
        let client = client
        let result: Result<LeoChatPage, any Error>
        do {
            result = .success(try await client.messages(agent: agent.name, query: query))
        } catch {
            result = .failure(error)
        }
        guard token == loadToken, agent == self.agent, query.task == timeline.taskFilter else { return nil }
        return result
    }

    private func apply(_ result: Result<LeoChatPage, any Error>) {
        switch result {
        case .success(let page):
            loadError = nil
            timeline.mergePage(page)
        case .failure(let error):
            timeline.endFetch()
            loadError = error.localizedDescription
        }
    }

    /// Best effort, and only for the unfiltered thread on screen: a failure
    /// only leaves the unread count up.
    private func markRead(_ id: String) async {
        guard isOnScreen, timeline.taskFilter == nil, let agent, agent.host == host, id != lastRead else { return }
        lastRead = id
        try? await client.markRead(agent: agent.name, upTo: id)
    }

    // MARK: Answers

    func askDraft(for messageID: String) -> LeoChatAskDraft { askDrafts[messageID] ?? LeoChatAskDraft() }

    /// The answer Submit would send, or nil while the daemon would refuse
    /// it (or the prompt isn't taking input).
    func askAnswer(for messageID: String) -> LeoChatAnswer? {
        guard let input = openAskInput(messageID) else { return nil }
        return askDraft(for: messageID).answer(for: input)
    }

    /// A choice clicked: `buttons` (and permission prompts) answer at once,
    /// `radio` and `checkboxes` update the draft.
    func choose(messageID: String, value: String) async {
        guard let input = openAskInput(messageID) else { return }
        let draft = askDraft(for: messageID).choosing(value, in: input)
        guard input.kind == .buttons else {
            askDrafts[messageID] = draft
            return
        }
        guard let answer = draft.answer(for: input) else { return }
        await self.answer(messageID: messageID, answer)
    }

    func setAskText(messageID: String, _ text: String) {
        guard openAskInput(messageID) != nil, askDraft(for: messageID).text != text else { return }
        askDrafts[messageID] = askDraft(for: messageID).withText(text)
    }

    func submitAsk(messageID: String) async {
        guard let answer = askAnswer(for: messageID) else { return }
        await self.answer(messageID: messageID, answer)
    }

    /// Sends `answer`. A prompt settled meanwhile (409) just refetches the
    /// thread; any other refusal says why and keeps the draft.
    func answer(messageID: String, _ answer: LeoChatAnswer) async {
        guard let agent, timeline.message(id: messageID) != nil, answering.insert(messageID).inserted else { return }
        let client = client
        defer { answering.remove(messageID) }
        do {
            let updated = try await client.answer(agent: agent.name, messageID: messageID, answer: answer)
            guard agent == self.agent else { return }
            if let updated, timeline.admits(updated, agent: agent.name) {
                timeline.merge([updated])
            } else if let message = timeline.message(id: messageID) {
                timeline.merge([message.answered(answer)])
            }
        } catch LeoChatAnswerError.settled {
            askDrafts[messageID] = nil
            guard agent == self.agent else { return }
            await refreshSettled(messageID, agent: agent)
        } catch {
            notice = "Couldn't answer: \(error.localizedDescription)"
        }
    }

    /// Resyncs after a 409. The newest page may not reach back to the
    /// prompt; if it still shows open, the page just above it carries its
    /// settled copy.
    private func refreshSettled(_ messageID: String, agent: LeoAgentID) async {
        await loadNewest()
        guard agent == self.agent, timeline.message(id: messageID)?.isOpen == true,
              let index = timeline.messages.firstIndex(where: { $0.id == messageID }),
              index + 1 < timeline.messages.count else { return }
        let query = LeoChatPageQuery(before: timeline.messages[index + 1].id, limit: 1, task: timeline.taskFilter)
        let client = client
        guard let page = try? await client.messages(agent: agent.name, query: query), agent == self.agent else { return }
        timeline.merge(page.messages.filter { $0.id == messageID && timeline.admits($0, agent: agent.name) })
    }

    /// The input of a shown prompt that is open and not being answered.
    private func openAskInput(_ messageID: String) -> LeoChatInput? {
        guard let message = timeline.message(id: messageID), message.isOpen, !answering.contains(messageID) else { return nil }
        return message.answerInput
    }

    private func dropSettledAskDrafts() {
        guard !askDrafts.isEmpty else { return }
        let settled = askDrafts.keys.filter { timeline.message(id: $0).map { !$0.isOpen } ?? false }
        guard !settled.isEmpty else { return }
        settled.forEach { askDrafts[$0] = nil }
    }

    // MARK: Attachments

    /// Downloads `attachment` once into the attachment folder; a failure
    /// can be retried.
    func loadAttachment(_ attachment: LeoChatAttachment) async {
        guard attachment.available else { return }
        switch attachmentFiles[attachment.id] {
        case .loading, .loaded: return
        case .failed, nil: break
        }
        let folderName = LeoChatPresentation.safeFilename(attachment.id, fallback: "attachment")
        let folder = attachmentDirectory.appending(path: folderName)
        guard let url = LeoChatPresentation.contained(
            folder.appending(path: LeoChatPresentation.safeFilename(attachment.filename, fallback: folderName)), in: attachmentDirectory
        ) else {
            attachmentFiles[attachment.id] = .failed("Refused an attachment name outside the download folder.")
            return
        }
        attachmentFiles[attachment.id] = .loading
        let client = client
        do {
            let data = try await client.download(attachmentID: attachment.id)
            try await Task.detached {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }.value
            attachmentFiles[attachment.id] = .loaded(url)
        } catch {
            attachmentFiles[attachment.id] = .failed(error.localizedDescription)
        }
    }

    // MARK: Composer

    func draft(for agent: LeoAgentID) -> LeoChatComposerDraft { drafts[agent] ?? .empty }

    func isSending(_ agent: LeoAgentID) -> Bool { sending[agent] != nil }

    var canSend: Bool {
        guard let agent else { return false }
        return !isSending(agent) && draft(for: agent).outgoing != nil
    }

    var isRecording: Bool { recording != .idle }

    func setText(_ text: String) {
        guard let agent, draft(for: agent).text != text else { return }
        updateDraft(agent) { $0.text = text }
    }

    func setReply(to messageID: String?) {
        guard let agent else { return }
        updateDraft(agent) { $0.replyTo = messageID }
    }

    /// Attaches files to `agent`'s draft: the agent the drop or picker
    /// started for, even if the selection has moved since. Folders,
    /// unreadable files and files over the upload cap are refused (the
    /// first refusal throws, and nothing is attached).
    func addFiles(_ urls: [URL], to agent: LeoAgentID) throws {
        let files = try urls.map(outgoingFile)
        guard !files.isEmpty else { return }
        notice = nil
        updateDraft(agent) { $0.files.append(contentsOf: files) }
    }

    func removeFile(_ id: UUID) {
        guard let agent else { return }
        updateDraft(agent) { $0.files.removeAll { $0.id == id } }
    }

    func send() async {
        guard let agent else { return }
        await send(agent)
    }

    /// Uploads the draft's files, then sends; clears only what was sent.
    /// One send per agent at a time; a failure keeps the draft.
    private func send(_ agent: LeoAgentID) async {
        guard agent.host == host, sending[agent] == nil, let outgoing = draft(for: agent).outgoing else { return }
        sending[agent] = outgoing
        notice = nil
        defer { sending[agent] = nil }
        let (client, readFile) = (client, readFile)
        do {
            var ids: [String] = []
            for file in outgoing.files {
                ids.append(try await client.upload(try await readFile(file)).id)
            }
            let message = try await client.send(
                agent: agent.name, LeoChatDraft(text: outgoing.text, replyTo: outgoing.replyTo, attachmentIDs: ids)
            )
            drafts[agent] = draft(for: agent).finishing(outgoing)
            Self.deleteVoiceNotes(outgoing.files)
            // The live event may have brought it (newer) already.
            if agent == self.agent, timeline.message(id: message.id) == nil, timeline.admits(message, agent: agent.name) {
                timeline.merge([message])
            }
        } catch {
            notice = "Couldn't send: \(error.localizedDescription)"
        }
    }

    private func updateDraft(_ agent: LeoAgentID, _ change: (inout LeoChatComposerDraft) -> Void) {
        var draft = draft(for: agent)
        change(&draft)
        drafts[agent] = draft == .empty ? nil : draft
    }

    private func outgoingFile(_ url: URL) throws -> LeoChatOutgoingFile {
        let name = url.lastPathComponent
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else {
            throw LeoChatFileError.unreadable(name)
        }
        if values.isDirectory == true { throw LeoChatFileError.directory(name) }
        let bytes = values.fileSize ?? 0
        guard bytes <= maximumUploadBytes else { throw LeoChatFileError.tooLarge(name, bytes: bytes, limit: maximumUploadBytes) }
        return LeoChatOutgoingFile(id: UUID(), url: url, filename: name, mime: LeoChatPresentation.mime(forFilename: name), isVoiceNote: false)
    }

    // MARK: Voice notes

    /// The mic button: starts recording, or finishes the note (which joins
    /// the draft and sends at once unless a send is already in flight).
    func toggleRecording() async {
        switch recording {
        case .idle: await startRecording()
        case .recording: await finishRecording()
        case .requesting: return
        }
    }

    func cancelRecording() {
        guard recording != .idle else { return }
        if case .recording = recording { recorder.cancel() }
        recording = .idle
    }

    private func startRecording() async {
        guard let agent, agent.host == host else { return }
        recording = .requesting
        notice = nil
        guard await recorder.requestPermission() else {
            recording = .idle
            notice = Self.microphoneDeniedMessage
            return
        }
        // Cancelled while the permission prompt was up.
        guard recording == .requesting else { return }
        let folder = attachmentDirectory.appending(path: "recordings")
        let url = folder.appending(path: "voice-\(UUID().uuidString).m4a")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try recorder.start(url: url, limit: Self.maximumRecording) { [weak self] in
                Task { await self?.finishRecording() }
            }
            recording = .recording(url: url, agent: agent, startedAt: Date())
        } catch {
            recording = .idle
            notice = "Couldn't record: \(error.localizedDescription)"
        }
    }

    private func finishRecording() async {
        guard case .recording(let url, let agent, _) = recording else { return }
        let duration = recorder.stop()
        recording = .idle
        guard duration >= Self.minimumRecording else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let note = LeoChatOutgoingFile(id: UUID(), url: url, filename: "Voice note.m4a", mime: "audio/mp4", isVoiceNote: true)
        updateDraft(agent) { $0.files.append(note) }
        await send(agent)
    }

    private static func deleteVoiceNotes(_ files: [LeoChatOutgoingFile]) {
        for file in files where file.isVoiceNote { try? FileManager.default.removeItem(at: file.url) }
    }

    nonisolated static func readFromDisk(_ file: LeoChatOutgoingFile) async throws -> LeoChatUpload {
        try await Task.detached {
            guard let data = try? Data(contentsOf: file.url) else { throw LeoChatFileError.unreadable(file.filename) }
            return LeoChatUpload(filename: file.filename, mime: file.mime, data: data)
        }.value
    }
}
