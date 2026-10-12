import Foundation
import OSLog

private var uploadLogger: Logger { LeoLog.logger() }

/// Chat uploads on a background `URLSession`, so a voice note or photo
/// keeps uploading when the app leaves the foreground. A background session
/// only uploads from a file: the request body is written to a temporary
/// file first and removed once the task ends.
///
/// The awaiting caller lives only as long as the process: if the system
/// relaunches the app to finish an upload, the result is logged and
/// dropped (the attachment stays unsent on the daemon).
public final class LeoBackgroundUploadSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public static let identifier = "studio.blackpaw.leo.chat-uploads"
    /// One per process: a background session identifier must be unique.
    public static let shared = LeoBackgroundUploadSession()

    private struct Pending {
        let continuation: CheckedContinuation<LeoHTTPResponse, any Error>
        let file: URL
        var body = Data()
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var finishEvents: (@Sendable () -> Void)?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    override private init() {}

    /// The app delegate's `handleEventsForBackgroundURLSession` handler;
    /// called once the session has delivered its queued events.
    public func setFinishEventsHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { finishEvents = handler }
        _ = session
    }

    public func upload(_ request: URLRequest, body: Data) async throws -> LeoHTTPResponse {
        let file = FileManager.default.temporaryDirectory.appending(path: "leo-upload-\(UUID().uuidString)")
        try body.write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: file)
            lock.withLock { pending[task.taskIdentifier] = Pending(continuation: continuation, file: file) }
            task.resume()
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { pending[dataTask.taskIdentifier]?.body.append(data) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else {
            uploadLogger.log("chatUpload: task \(task.taskIdentifier) finished with no waiting caller error=\(String(describing: error), privacy: .public)")
            return
        }
        try? FileManager.default.removeItem(at: entry.file)
        if let error = error as? URLError {
            entry.continuation.resume(throwing: LeoHTTPSTransport.transportError(error))
        } else if let error {
            entry.continuation.resume(throwing: error)
        } else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            entry.continuation.resume(returning: LeoHTTPResponse(status: status, body: entry.body))
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { finishEvents = nil }
            return finishEvents
        }
        DispatchQueue.main.async { handler?() }
    }
}

/// `LeoChatTransport` that sends through `LeoBackgroundUploadSession`;
/// meant for `LeoChatHTTPClient.upload`.
public struct LeoBackgroundUploadTransport: LeoChatTransport {
    private let transport: LeoHTTPSTransport
    private let session: LeoBackgroundUploadSession

    public init(endpoint: LeoRemoteEndpoint, session: LeoBackgroundUploadSession = .shared) {
        transport = LeoHTTPSTransport(endpoint: endpoint)
        self.session = session
    }

    public func send(_ request: LeoHTTPRequest, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        var urlRequest = try transport.urlRequest(for: request, timeout: timeout)
        let body = urlRequest.httpBody ?? Data()
        urlRequest.httpBody = nil
        return try await session.upload(urlRequest, body: body)
    }
}
