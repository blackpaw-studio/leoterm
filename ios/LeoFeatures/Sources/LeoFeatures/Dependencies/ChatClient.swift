import ComposableArchitecture
import Foundation
import LeoKit

/// A local file to send: a photo, a picked file or a voice note.
public struct ChatFile: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable { case file, photo, voice }

    public let id: UUID
    public let url: URL
    public let filename: String
    public let mime: String
    public let kind: Kind

    public init(id: UUID, url: URL, filename: String, mime: String, kind: Kind) {
        self.id = id
        self.url = url
        self.filename = filename
        self.mime = mime
        self.kind = kind
    }
}

/// Leo Chat on paired daemons' web listeners.
@DependencyClient
public struct ChatClient: Sendable {
    public var threads: @Sendable (_ connection: DaemonConnection) async throws -> [LeoChatThread]
    public var messages: @Sendable (_ connection: DaemonConnection, _ agent: String, _ query: LeoChatPageQuery) async throws -> LeoChatPage
    public var send: @Sendable (_ connection: DaemonConnection, _ agent: String, _ draft: LeoChatDraft) async throws -> LeoChatMessage
    /// Uploads in the foreground (same-origin redirects only); returns the
    /// stored attachment. Callers keep the app alive with `BackgroundTaskClient`.
    public var upload: @Sendable (_ connection: DaemonConnection, _ file: ChatFile) async throws -> LeoChatAttachment
    /// The attachment as a local file (cached per attachment id).
    public var download: @Sendable (_ connection: DaemonConnection, _ attachment: LeoChatAttachment) async throws -> URL
    /// Throws `LeoChatAnswerError` when the daemon refuses the answer or
    /// the prompt is already settled.
    public var answer: @Sendable (_ connection: DaemonConnection, _ agent: String, _ messageID: String, _ answer: LeoChatAnswer) async throws -> LeoChatMessage?
    public var markRead: @Sendable (_ connection: DaemonConnection, _ agent: String, _ messageID: String) async throws -> Void
}

extension ChatClient: DependencyKey {
    public static let testValue = ChatClient()

    public static var liveValue: ChatClient {
        let session = URLSession(configuration: .default)
        let cache = URL.cachesDirectory.appending(path: "leo-chat-attachments", directoryHint: .isDirectory)
        @Sendable func client(_ connection: DaemonConnection) -> LeoChatHTTPClient {
            LeoChatHTTPClient(transport: LeoHTTPSTransport(endpoint: connection.endpoint, session: session))
        }
        return ChatClient(
            threads: { try await client($0).threads() },
            messages: { connection, agent, query in try await client(connection).messages(agent: agent, query: query) },
            send: { connection, agent, draft in try await client(connection).send(agent: agent, draft) },
            upload: { connection, file in
                let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
                return try await client(connection).upload(LeoChatUpload(filename: file.filename, mime: file.mime, data: data))
            },
            download: { connection, attachment in
                let folder = cache
                    .appending(path: ChatClient.safeComponent(connection.daemonID), directoryHint: .isDirectory)
                    .appending(path: ChatClient.safeComponent(attachment.id), directoryHint: .isDirectory)
                let url = folder.appending(path: ChatClient.safeComponent(attachment.filename))
                if FileManager.default.fileExists(atPath: url.path()) { return url }
                let data = try await client(connection).download(attachmentID: attachment.id)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return url
            },
            answer: { connection, agent, messageID, answer in try await client(connection).answer(agent: agent, messageID: messageID, answer: answer) },
            markRead: { connection, agent, messageID in try await client(connection).markRead(agent: agent, upTo: messageID) }
        )
    }
}

/// Records voice notes (AAC in an `.m4a`). The app provides the live value.
@DependencyClient
public struct AudioRecorderClient: Sendable {
    /// Asks for the microphone once; afterwards answers from the setting.
    public var requestPermission: @Sendable () async -> Bool = { false }
    public var start: @Sendable (_ url: URL) async throws -> Void
    /// Stops and returns the recorded length in seconds.
    public var stop: @Sendable () async -> TimeInterval = { 0 }
    /// Stops and deletes the recording.
    public var cancel: @Sendable () async -> Void
}

extension AudioRecorderClient: TestDependencyKey {
    public static let testValue = AudioRecorderClient()
}

/// Keeps the app running long enough to finish work the user started (a
/// send and its uploads) after it leaves the foreground. The app provides
/// the live value (`UIApplication` background tasks).
@DependencyClient
public struct BackgroundTaskClient: Sendable {
    /// Asks the system for time to finish `name`; returns a token for `end`.
    public var begin: @Sendable (_ name: String) async -> Int = { _ in 0 }
    public var end: @Sendable (_ token: Int) async -> Void
}

extension BackgroundTaskClient: TestDependencyKey {
    public static let testValue = BackgroundTaskClient()

    /// Runs `operation` inside one background task, ending it however
    /// `operation` finishes.
    public func run<T: Sendable>(_ name: String, _ operation: @Sendable () async throws -> T) async throws -> T {
        let token = await begin(name)
        do {
            let value = try await operation()
            await end(token)
            return value
        } catch {
            await end(token)
            throw error
        }
    }
}

/// Tells the user, out of band, that a notification action failed (the
/// app may be in the background). The app provides the live value.
@DependencyClient
public struct ChatNotifierClient: Sendable {
    public var actionFailed: @Sendable (_ agent: String, _ reason: String) async -> Void
}

extension ChatNotifierClient: TestDependencyKey {
    public static let testValue = ChatNotifierClient()
}

extension DependencyValues {
    public var chatClient: ChatClient {
        get { self[ChatClient.self] }
        set { self[ChatClient.self] = newValue }
    }

    public var audioRecorder: AudioRecorderClient {
        get { self[AudioRecorderClient.self] }
        set { self[AudioRecorderClient.self] = newValue }
    }

    public var backgroundTask: BackgroundTaskClient {
        get { self[BackgroundTaskClient.self] }
        set { self[BackgroundTaskClient.self] = newValue }
    }

    public var chatNotifier: ChatNotifierClient {
        get { self[ChatNotifierClient.self] }
        set { self[ChatNotifierClient.self] = newValue }
    }
}

extension ChatClient {
    /// A name safe as one path component.
    static func safeComponent(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "file\(cleaned)" : cleaned
    }
}

/// The connection for a daemon, from its saved credentials.
public enum ChatConnectionError: Error, Equatable, LocalizedError {
    case missingCredentials

    public var errorDescription: String? { String(localized: "No saved token for this daemon. Pair it again.") }
}

extension SecretsClient {
    func connection(for daemon: PairedDaemon) throws -> DaemonConnection {
        guard let secrets = try load(daemon.id) else { throw ChatConnectionError.missingCredentials }
        return DaemonConnection(daemon: daemon, secrets: secrets)
    }
}
