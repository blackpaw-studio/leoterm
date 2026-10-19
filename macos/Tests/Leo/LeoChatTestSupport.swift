import Foundation
@testable import Ghostty
@testable import LeoKit

/// A scripted `LeoChatClient`: pages come off a queue (optionally held until
/// released, to interleave live events), and every call is recorded.
actor FakeChatClient: LeoChatClient {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var pageRequests: [(agent: String, query: LeoChatPageQuery)] = []
    private(set) var sent: [(agent: String, draft: LeoChatDraft)] = []
    private(set) var uploads: [LeoChatUpload] = []
    private(set) var reads: [(agent: String, id: String)] = []
    private(set) var answers: [(agent: String, id: String, answer: LeoChatAnswer)] = []
    private(set) var questionAnswers: [(agent: String, id: String, answers: [String: LeoChatAnswer])] = []
    private(set) var dismissals: [(agent: String, id: String)] = []
    private(set) var downloadCount = 0
    private(set) var threadRequestCount = 0

    private var pages: [Result<LeoChatPage, Failure>] = []
    private var isHoldingPages = false
    private var heldPages: [CheckedContinuation<Void, Never>] = []
    private var pageWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var sendResults: [Result<LeoChatMessage, Failure>] = []
    private var isHoldingSends = false
    private var heldSends: [CheckedContinuation<Void, Never>] = []
    private var uploadFailure: Failure?
    private var answerResult: Result<LeoChatMessage?, any Error> = .success(nil)
    private var questionsResult: Result<LeoChatMessage?, any Error> = .success(nil)
    private var isHoldingQuestions = false
    private var heldQuestions: [CheckedContinuation<Void, Never>] = []
    private var isHoldingDismissals = false
    private var heldDismissals: [CheckedContinuation<Void, Never>] = []
    private var dismissResult: Result<LeoChatMessage?, any Error> = .success(nil)
    private var downloads: [String: Result<Data, Failure>] = [:]
    private var isHoldingDownloads = false
    private var heldDownloads: [CheckedContinuation<Void, Never>] = []
    private var readFailure: Failure?
    private var threadsResult: Result<[LeoChatThread], Failure> = .success([])
    private var isHoldingThreads = false
    private var heldThreads: [CheckedContinuation<Void, Never>] = []
    private var threadWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func enqueuePage(_ messages: [LeoChatMessage], hasMore: Bool = false) {
        pages.append(.success(LeoChatPage(messages: messages, hasMore: hasMore)))
    }

    func enqueuePageFailure(_ message: String) { pages.append(.failure(Failure(message: message))) }
    func enqueueSend(_ result: Result<LeoChatMessage, Failure>) { sendResults.append(result) }
    func failUploads(_ message: String) { uploadFailure = Failure(message: message) }
    func setAnswerResult(_ result: Result<LeoChatMessage?, any Error>) { answerResult = result }
    func setQuestionsResult(_ result: Result<LeoChatMessage?, any Error>) { questionsResult = result }
    func holdQuestionAnswers() { isHoldingQuestions = true }

    func releaseQuestionAnswers() {
        isHoldingQuestions = false
        heldQuestions.forEach { $0.resume() }
        heldQuestions = []
    }

    /// Returns once `count` questions answers have arrived.
    func waitForQuestionAnswers(_ count: Int) async {
        while questionAnswers.count < count { await Task.yield() }
    }

    func holdDismissals() { isHoldingDismissals = true }

    func releaseDismissals() {
        isHoldingDismissals = false
        heldDismissals.forEach { $0.resume() }
        heldDismissals = []
    }

    /// Returns once `count` dismissals have arrived.
    func waitForDismissals(_ count: Int) async {
        while dismissals.count < count { await Task.yield() }
    }

    func setDismissResult(_ result: Result<LeoChatMessage?, any Error>) { dismissResult = result }
    func setDownload(_ id: String, _ result: Result<Data, Failure>) { downloads[id] = result }
    func failReads(_ message: String) { readFailure = Failure(message: message) }
    func setThreads(_ threads: [LeoChatThread]) { threadsResult = .success(threads) }
    func failThreads(_ message: String) { threadsResult = .failure(Failure(message: message)) }
    func holdThreads() { isHoldingThreads = true }
    func holdPages() { isHoldingPages = true }

    /// Lets every held `threads()` request answer.
    func releaseThreads() {
        isHoldingThreads = false
        heldThreads.forEach { $0.resume() }
        heldThreads = []
    }

    /// Returns once `count` `threads()` requests have arrived.
    func waitForThreadRequests(_ count: Int) async {
        guard threadRequestCount < count else { return }
        await withCheckedContinuation { threadWaiters.append((count, $0)) }
    }
    func holdSends() { isHoldingSends = true }

    /// Lets the oldest held page request answer.
    func releasePage() {
        guard !heldPages.isEmpty else { return }
        heldPages.removeFirst().resume()
    }

    func releaseSend() {
        isHoldingSends = false
        heldSends.forEach { $0.resume() }
        heldSends = []
    }

    /// Returns once `count` page requests have arrived.
    func waitForPageRequests(_ count: Int) async {
        guard pageRequests.count < count else { return }
        await withCheckedContinuation { pageWaiters.append((count, $0)) }
    }

    func threads() async throws -> [LeoChatThread] {
        threadRequestCount += 1
        let ready = threadWaiters.filter { $0.count <= threadRequestCount }
        threadWaiters.removeAll { $0.count <= threadRequestCount }
        ready.forEach { $0.continuation.resume() }
        let result = threadsResult
        if isHoldingThreads { await withCheckedContinuation { heldThreads.append($0) } }
        return try result.get()
    }

    func messages(agent: String, query: LeoChatPageQuery) async throws -> LeoChatPage {
        pageRequests.append((agent, query))
        let ready = pageWaiters.filter { $0.count <= pageRequests.count }
        pageWaiters.removeAll { $0.count <= pageRequests.count }
        ready.forEach { $0.continuation.resume() }
        if isHoldingPages { await withCheckedContinuation { heldPages.append($0) } }
        guard !pages.isEmpty else { return LeoChatPage(messages: [], hasMore: false) }
        return try pages.removeFirst().get()
    }

    func send(agent: String, _ draft: LeoChatDraft) async throws -> LeoChatMessage {
        sent.append((agent, draft))
        if isHoldingSends { await withCheckedContinuation { heldSends.append($0) } }
        guard !sendResults.isEmpty else {
            return chatMessage("sent-\(sent.count)", agent: agent, direction: .inbound, text: draft.text, at: 1000 + sent.count)
        }
        return try sendResults.removeFirst().get()
    }

    func upload(_ upload: LeoChatUpload) async throws -> LeoChatAttachment {
        uploads.append(upload)
        if let uploadFailure { throw uploadFailure }
        return LeoChatAttachment(id: "att-\(uploads.count)", filename: upload.filename, mime: upload.mime, bytes: upload.data.count)
    }

    func holdDownloads() { isHoldingDownloads = true }

    func releaseDownloads() {
        isHoldingDownloads = false
        heldDownloads.forEach { $0.resume() }
        heldDownloads = []
    }

    /// Returns once `count` downloads have started.
    func waitForDownloads(_ count: Int) async {
        while downloadCount < count { await Task.yield() }
    }

    func download(attachmentID: String) async throws -> Data {
        downloadCount += 1
        if isHoldingDownloads { await withCheckedContinuation { heldDownloads.append($0) } }
        return try (downloads[attachmentID] ?? .failure(Failure(message: "missing"))).get()
    }

    func answer(agent: String, messageID: String, answer: LeoChatAnswer) async throws -> LeoChatMessage? {
        answers.append((agent, messageID, answer))
        return try answerResult.get()
    }

    func answerQuestions(agent: String, messageID: String, answers: [String: LeoChatAnswer]) async throws -> LeoChatMessage? {
        questionAnswers.append((agent, messageID, answers))
        if isHoldingQuestions { await withCheckedContinuation { heldQuestions.append($0) } }
        return try questionsResult.get()
    }

    func dismiss(agent: String, messageID: String) async throws -> LeoChatMessage? {
        dismissals.append((agent, messageID))
        if isHoldingDismissals { await withCheckedContinuation { heldDismissals.append($0) } }
        return try dismissResult.get()
    }

    func markRead(agent: String, upTo messageID: String) async throws {
        reads.append((agent, messageID))
        if let readFailure { throw readFailure }
    }
}

/// A scripted voice recorder.
@MainActor final class FakeVoiceRecorder: LeoChatVoiceRecording {
    var isPermitted = true
    var duration: TimeInterval = 3
    var startError: Error?
    private(set) var started: [(url: URL, limit: TimeInterval)] = []
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private var onLimit: (@MainActor () -> Void)?

    func requestPermission() async -> Bool { isPermitted }

    func start(url: URL, limit: TimeInterval, onLimit: @escaping @MainActor () -> Void) throws {
        if let startError { throw startError }
        started.append((url, limit))
        self.onLimit = onLimit
    }

    /// Finalizes the file, as the real recorder does.
    func stop() -> TimeInterval {
        stopCount += 1
        if let url = started.last?.url { try? Data([1, 2, 3]).write(to: url) }
        return duration
    }

    func cancel() { cancelCount += 1 }

    /// The recorder hit its cap on its own.
    func reachLimit() { onLimit?() }
}

func chatMessage(
    _ id: String, agent: String = "alpha", direction: LeoChatMessage.Direction = .outbound, kind: LeoChatMessage.Kind = .text,
    text: String = "hi", task: String? = nil, state: String? = nil, at seconds: Int, input: LeoChatInput? = nil
) -> LeoChatMessage {
    LeoChatMessage(
        id: id, agent: agent, direction: direction, kind: kind, text: text, task: task, state: state,
        ts: Date(timeIntervalSince1970: TimeInterval(seconds)), input: input
    )
}
