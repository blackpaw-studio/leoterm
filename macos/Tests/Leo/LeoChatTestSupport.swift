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
    private(set) var answers: [(agent: String, id: String, value: String)] = []
    private(set) var downloadCount = 0

    private var pages: [Result<LeoChatPage, Failure>] = []
    private var isHoldingPages = false
    private var heldPages: [CheckedContinuation<Void, Never>] = []
    private var pageWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var sendResults: [Result<LeoChatMessage, Failure>] = []
    private var isHoldingSends = false
    private var heldSends: [CheckedContinuation<Void, Never>] = []
    private var uploadFailure: Failure?
    private var answerResult: Result<LeoChatMessage?, Failure> = .success(nil)
    private var downloads: [String: Result<Data, Failure>] = [:]

    func enqueuePage(_ messages: [LeoChatMessage], hasMore: Bool = false) {
        pages.append(.success(LeoChatPage(messages: messages, hasMore: hasMore)))
    }

    func enqueuePageFailure(_ message: String) { pages.append(.failure(Failure(message: message))) }
    func enqueueSend(_ result: Result<LeoChatMessage, Failure>) { sendResults.append(result) }
    func failUploads(_ message: String) { uploadFailure = Failure(message: message) }
    func setAnswerResult(_ result: Result<LeoChatMessage?, Failure>) { answerResult = result }
    func setDownload(_ id: String, _ result: Result<Data, Failure>) { downloads[id] = result }
    func holdPages() { isHoldingPages = true }
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

    func threads() async throws -> [LeoChatThread] { [] }

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

    func download(attachmentID: String) async throws -> Data {
        downloadCount += 1
        return try (downloads[attachmentID] ?? .failure(Failure(message: "missing"))).get()
    }

    func answer(agent: String, messageID: String, value: String) async throws -> LeoChatMessage? {
        answers.append((agent, messageID, value))
        return try answerResult.get()
    }

    func markRead(agent: String, upTo messageID: String) async throws {
        reads.append((agent, messageID))
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
    text: String = "hi", task: String? = nil, state: String? = nil, at seconds: Int, options: [LeoChatOption] = []
) -> LeoChatMessage {
    LeoChatMessage(
        id: id, agent: agent, direction: direction, kind: kind, text: text, task: task, state: state,
        ts: Date(timeIntervalSince1970: TimeInterval(seconds)), options: options
    )
}
