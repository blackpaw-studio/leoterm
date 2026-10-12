import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Leo Chat on the Mac: the selected agent's thread (paging, live events,
/// resync, read marks), answering prompts, and the guarded composer.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct LeoChatPaneModelTests {
    private static let alpha = LeoAgentID(host: .local, name: "alpha")
    private static let beta = LeoAgentID(host: .local, name: "beta")

    private let client = FakeChatClient()
    private let recorder = FakeVoiceRecorder()
    private let directory = FileManager.default.temporaryDirectory.appending(path: "leo-chat-tests-\(UUID().uuidString)")

    private func make(maximumUploadBytes: Int = LeoChatUpload.maximumBytes) -> LeoChatPaneModel {
        LeoChatPaneModel(
            client: client, host: .local, recorder: recorder, attachmentDirectory: directory, maximumUploadBytes: maximumUploadBytes
        )
    }

    private func file(_ name: String, bytes: Int = 4) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    // MARK: Thread

    @Test func showLoadsNewestPageOldestFirst() async {
        await client.enqueuePage([chatMessage("b", task: "digest", at: 2), chatMessage("a", at: 1)], hasMore: true)
        let model = make()
        await model.show(Self.alpha)
        #expect(model.timeline.messages.map(\.id) == ["a", "b"])
        #expect(model.timeline.hasMore)
        #expect(model.timeline.knownTasks == ["digest"])
        #expect(await client.pageRequests.map(\.query) == [LeoChatPageQuery(limit: LeoChatPaneModel.pageSize)])
    }

    @Test func aPageForAPreviouslySelectedAgentIsDropped() async {
        await client.holdPages()
        await client.enqueuePage([chatMessage("a1", at: 1)])
        await client.enqueuePage([chatMessage("b1", agent: "beta", at: 1)])
        let model = make()
        let first = Task { await model.show(Self.alpha) }
        await client.waitForPageRequests(1)
        let second = Task { await model.show(Self.beta) }
        await client.waitForPageRequests(2)
        await client.releasePage()
        await first.value
        await client.releasePage()
        await second.value
        #expect(model.agent == Self.beta)
        #expect(model.timeline.messages.map(\.id) == ["b1"])
    }

    @Test func liveEventsMergeOnlyForTheShownThread() async {
        let model = make()
        await model.show(Self.alpha)
        await model.receive(.message(chatMessage("x", at: 5)), host: .local)
        await model.receive(.message(chatMessage("y", agent: "beta", at: 6)), host: .local)
        await model.receive(.message(chatMessage("z", at: 7)), host: .remote("far"))
        await model.receive(.updated(chatMessage("unknown", at: 8)), host: .local)
        #expect(model.timeline.messages.map(\.id) == ["x"])
    }

    @Test func aLiveUpdateDuringAFetchBeatsThePagesOlderCopy() async {
        await client.holdPages()
        await client.enqueuePage([chatMessage("q", kind: .ask, state: "open", at: 1)])
        let model = make()
        let load = Task { await model.show(Self.alpha) }
        await client.waitForPageRequests(1)
        await model.receive(.message(chatMessage("q", kind: .ask, state: "answered", at: 1)), host: .local)
        await client.releasePage()
        await load.value
        #expect(model.timeline.messages.map(\.state) == ["answered"])
    }

    @Test func loadOlderPagesBeforeTheOldestMessage() async {
        await client.enqueuePage([chatMessage("c", at: 3)], hasMore: true)
        await client.enqueuePage([chatMessage("b", at: 2), chatMessage("a", at: 1)], hasMore: false)
        let model = make()
        await model.show(Self.alpha)
        await model.loadOlder()
        #expect(model.timeline.messages.map(\.id) == ["a", "b", "c"])
        #expect(!model.timeline.hasMore)
        #expect(await client.pageRequests.last?.query == LeoChatPageQuery(before: "c", limit: LeoChatPaneModel.pageSize))
        await model.loadOlder()
        #expect(await client.pageRequests.count == 2)
    }

    @Test func taskFilterReloadsAndKeepsOtherTasksOut() async {
        await client.enqueuePage([chatMessage("t1", kind: .task, task: "digest", at: 1), chatMessage("m", at: 2)])
        await client.enqueuePage([chatMessage("t1", kind: .task, task: "digest", at: 1)])
        let model = make()
        await model.show(Self.alpha)
        await model.setTaskFilter("digest")
        #expect(await client.pageRequests.last?.query == LeoChatPageQuery(limit: LeoChatPaneModel.pageSize, task: "digest"))
        #expect(model.timeline.messages.map(\.id) == ["t1"])
        await model.receive(.message(chatMessage("t2", kind: .task, task: "other", at: 3)), host: .local)
        await model.receive(.message(chatMessage("t3", kind: .task, task: "digest", at: 4)), host: .local)
        #expect(model.timeline.messages.map(\.id) == ["t1", "t3"])
        #expect(model.timeline.knownTasks == ["digest"])
    }

    @Test func resyncReloadsTheNewestPageAndMergesById() async {
        await client.enqueuePage([chatMessage("b", at: 2)], hasMore: true)
        await client.enqueuePage([chatMessage("a", at: 1)])
        await client.enqueuePage([chatMessage("c", at: 3), chatMessage("b", text: "edited", at: 2)], hasMore: true)
        let model = make()
        await model.show(Self.alpha)
        await model.loadOlder()
        await model.resync(host: .local)
        #expect(model.timeline.messages.map(\.id) == ["a", "b", "c"])
        #expect(model.timeline.messages[1].text == "edited")
        await model.resync(host: .remote("far"))
        #expect(await client.pageRequests.count == 3)
    }

    @Test func aFailedLoadSaysWhy() async {
        await client.enqueuePageFailure("daemon is down")
        let model = make()
        await model.show(Self.alpha)
        #expect(model.loadError == "daemon is down")
        #expect(!model.isLoading)
    }

    // MARK: Read marks

    @Test func marksReadOnlyWhileOnScreenAndUnfiltered() async {
        await client.enqueuePage([chatMessage("a", at: 1)])
        let model = make()
        await model.show(Self.alpha)
        #expect(await client.reads.isEmpty)
        await model.setOnScreen(true)
        #expect(await client.reads.map(\.id) == ["a"])
        await model.receive(.message(chatMessage("b", at: 2)), host: .local)
        #expect(await client.reads.map(\.id) == ["a", "b"])
        await model.receive(.updated(chatMessage("b", text: "x", at: 2)), host: .local)
        #expect(await client.reads.count == 2)
        await model.setOnScreen(false)
        await model.receive(.message(chatMessage("c", at: 3)), host: .local)
        #expect(await client.reads.count == 2)
    }

    // MARK: Answers

    @Test func answeringMergesTheDaemonsCopyOrMarksItLocally() async {
        let ask = chatMessage("q", kind: .ask, state: "open", at: 1, options: [LeoChatOption(value: "y", label: "Yes")])
        await client.enqueuePage([ask, chatMessage("p", kind: .permission, state: "open", at: 0)])
        await client.setAnswerResult(.success(chatMessage("q", kind: .ask, state: "answered", at: 1)))
        let model = make()
        await model.show(Self.alpha)
        await model.answer(messageID: "q", value: "y")
        await client.setAnswerResult(.success(nil))
        await model.answer(messageID: "p", value: "allow")
        #expect(model.timeline.messages.map(\.state) == ["answered", "answered"])
        #expect(model.timeline.messages.first?.answer == "allow")
        #expect(model.answering.isEmpty)
        #expect(await client.answers.map(\.value) == ["y", "allow"])
    }

    @Test func aFailedAnswerKeepsThePromptOpenAndSaysWhy() async {
        await client.enqueuePage([chatMessage("q", kind: .ask, state: "open", at: 1)])
        await client.setAnswerResult(.failure(.init(message: "expired")))
        let model = make()
        await model.show(Self.alpha)
        await model.answer(messageID: "q", value: "y")
        #expect(model.timeline.messages.first?.isOpen == true)
        #expect(model.notice == "Couldn't answer: expired")
    }

    // MARK: Composer

    @Test func sendUploadsFilesThenSendsAndClearsOnlyWhatWasSent() async throws {
        await client.holdSends()
        let model = make()
        await model.show(Self.alpha)
        model.setText("  hello  ")
        try model.addFiles([try file("notes.txt")])
        let sending = Task { await model.send() }
        while await client.sent.isEmpty { await Task.yield() }
        model.setText("hello and more")
        try model.addFiles([try file("later.txt")])
        await client.releaseSend()
        await sending.value
        let sent = try #require(await client.sent.first)
        #expect(sent.draft == LeoChatDraft(text: "hello", attachmentIDs: ["att-1"]))
        #expect(await client.uploads.map(\.filename) == ["notes.txt"])
        #expect(model.draft(for: Self.alpha).text == "hello and more")
        #expect(model.draft(for: Self.alpha).files.map(\.filename) == ["later.txt"])
        #expect(model.timeline.messages.map(\.id) == ["sent-1"])
        #expect(!model.isSending(Self.alpha))
    }

    @Test func aFailedSendKeepsTheDraftAndSaysWhy() async throws {
        await client.failUploads("too big")
        let model = make()
        await model.show(Self.alpha)
        model.setText("hello")
        try model.addFiles([try file("a.txt")])
        await model.send()
        #expect(model.draft(for: Self.alpha).text == "hello")
        #expect(model.draft(for: Self.alpha).files.count == 1)
        #expect(model.notice == "Couldn't send: too big")
        #expect(await client.sent.isEmpty)
    }

    @Test func aSecondSendWhileOneIsInFlightIsIgnored() async {
        await client.holdSends()
        let model = make()
        await model.show(Self.alpha)
        model.setText("one")
        let first = Task { await model.send() }
        while await client.sent.isEmpty { await Task.yield() }
        #expect(!model.canSend)
        await model.send()
        await client.releaseSend()
        await first.value
        #expect(await client.sent.count == 1)
    }

    @Test func blankDraftsDontSend() async {
        let model = make()
        await model.show(Self.alpha)
        model.setText(" \n ")
        #expect(!model.canSend)
        await model.send()
        #expect(await client.sent.isEmpty)
    }

    @Test func replyingToATaskCardRidesOnTheSendThenClears() async {
        await client.enqueuePage([chatMessage("t", kind: .task, task: "digest", at: 1)])
        let model = make()
        await model.show(Self.alpha)
        model.setReply(to: "t")
        model.setText("why?")
        await model.send()
        #expect(await client.sent.first?.draft.replyTo == "t")
        #expect(model.draft(for: Self.alpha).replyTo == nil)
    }

    @Test func draftsAreKeptPerAgent() async {
        let model = make()
        await model.show(Self.alpha)
        model.setText("for alpha")
        await model.show(Self.beta)
        #expect(model.draft(for: Self.beta).text == "")
        await model.show(Self.alpha)
        #expect(model.draft(for: Self.alpha).text == "for alpha")
    }

    @Test func directoriesAndOversizedFilesAreRefused() async throws {
        let model = make(maximumUploadBytes: 8)
        await model.show(Self.alpha)
        try FileManager.default.createDirectory(at: directory.appending(path: "folder"), withIntermediateDirectories: true)
        #expect(throws: LeoChatFileError.self) { try model.addFiles([directory.appending(path: "folder")]) }
        #expect(throws: LeoChatFileError.self) { try model.addFiles([try file("big.bin", bytes: 9)]) }
        try model.addFiles([try file("small.bin", bytes: 8)])
        #expect(model.draft(for: Self.alpha).files.map(\.filename) == ["small.bin"])
    }

    // MARK: Voice notes

    @Test func aFinishedVoiceNoteJoinsTheDraftAndSends() async throws {
        let model = make()
        await model.show(Self.alpha)
        await model.toggleRecording()
        let started = try #require(recorder.started.first)
        #expect(started.limit == LeoChatPaneModel.maximumRecording)
        #expect(model.isRecording)
        await model.toggleRecording()
        #expect(!model.isRecording)
        let upload = try #require(await client.uploads.first)
        #expect(upload.mime == "audio/mp4")
        #expect(upload.filename.hasSuffix(".m4a"))
        #expect(await client.sent.count == 1)
    }

    @Test func aVoiceNoteReachingTheCapFinishesOnItsOwn() async throws {
        let model = make()
        await model.show(Self.alpha)
        await model.toggleRecording()
        recorder.reachLimit()
        while model.isRecording { await Task.yield() }
        #expect(recorder.stopCount == 1)
    }

    @Test func aTapIsNotARecording() async {
        recorder.duration = 0.2
        let model = make()
        await model.show(Self.alpha)
        await model.toggleRecording()
        await model.toggleRecording()
        #expect(model.draft(for: Self.alpha).files.isEmpty)
        #expect(await client.uploads.isEmpty)
    }

    @Test func deniedMicrophoneSaysSo() async {
        recorder.isPermitted = false
        let model = make()
        await model.show(Self.alpha)
        await model.toggleRecording()
        #expect(!model.isRecording)
        #expect(model.notice == LeoChatPaneModel.microphoneDeniedMessage)
    }

    @Test func cancellingDiscardsTheRecording() async {
        let model = make()
        await model.show(Self.alpha)
        await model.toggleRecording()
        model.cancelRecording()
        #expect(!model.isRecording)
        #expect(recorder.cancelCount == 1)
        #expect(model.draft(for: Self.alpha).files.isEmpty)
    }

    // MARK: Attachments

    @Test func attachmentsDownloadOnceToASanitizedFile() async throws {
        await client.setDownload("f1", .success(Data("pdf".utf8)))
        let model = make()
        let attachment = LeoChatAttachment(id: "f1", filename: "../../etc/passwd", mime: "application/pdf", bytes: 3)
        await model.loadAttachment(attachment)
        await model.loadAttachment(attachment)
        guard case .loaded(let url) = model.attachmentFiles["f1"] else {
            Issue.record("expected a loaded file")
            return
        }
        #expect(url.lastPathComponent == "passwd")
        #expect(url.path.hasPrefix(directory.path))
        #expect(try Data(contentsOf: url) == Data("pdf".utf8))
        #expect(await client.downloadCount == 1)
    }

    @Test func aFailedDownloadCanBeRetried() async {
        await client.setDownload("f1", .failure(.init(message: "gone")))
        let model = make()
        let attachment = LeoChatAttachment(id: "f1", filename: "a.png", mime: "image/png", bytes: 3)
        await model.loadAttachment(attachment)
        #expect(model.attachmentFiles["f1"] == .failed("gone"))
        await model.loadAttachment(attachment)
        #expect(await client.downloadCount == 2)
    }
}

@Suite struct LeoChatPresentationTests {
    @Test func longRepliesCollapse() {
        #expect(!LeoChatPresentation.isLong("short"))
        #expect(LeoChatPresentation.isLong(String(repeating: "x", count: LeoChatPresentation.collapsedCharacters + 1)))
        #expect(LeoChatPresentation.isLong(Array(repeating: "line", count: LeoChatPresentation.collapsedLines + 1).joined(separator: "\n")))
    }

    @Test func attachmentNamesStayInsideTheirFolder() {
        #expect(LeoChatPresentation.safeFilename("../../etc/passwd", fallback: "f") == "passwd")
        #expect(LeoChatPresentation.safeFilename(".hidden", fallback: "f") == "hidden")
        #expect(LeoChatPresentation.safeFilename("", fallback: "f1") == "f1")
        #expect(LeoChatPresentation.safeFilename("..", fallback: "f1") == "f1")
    }
}
