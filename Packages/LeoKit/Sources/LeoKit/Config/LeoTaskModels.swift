import CryptoKit
import Foundation

/// `POST /tasks/{name}/run`: 202, the run is detached.
public struct LeoTaskRunStart: Decodable, Equatable, Sendable {
    public let name: String
    public let status: String

    public init(name: String, status: String) {
        self.name = name
        self.status = status
    }
}

/// One entry of `GET /tasks/{name}/history`, newest first.
public struct LeoTaskRun: Decodable, Equatable, Sendable, Identifiable {
    public let task: String
    public let startedAt: Date?
    public let exitCode: Int?
    public let durationMs: Int?
    /// The run's log under the task's logs; empty when it left none.
    public let logFile: String
    private let startedAtText: String

    public init(task: String, startedAt: Date?, exitCode: Int?, durationMs: Int?, logFile: String) {
        self.task = task
        self.startedAt = startedAt
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.logFile = logFile
        startedAtText = startedAt.map { $0.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)) } ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case task
        case startedAt = "started_at"
        case exitCode = "exit_code"
        case durationMs = "duration_ms"
        case logFile = "log_file"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
        task = try container.decodeIfPresent(String.self, forKey: .task) ?? ""
        startedAtText = text
        startedAt = Self.date(text)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        logFile = try container.decodeIfPresent(String.self, forKey: .logFile) ?? ""
    }

    /// The run's log name, which is unique per run, else the task and start.
    public var id: String { logFile.isEmpty ? "\(task)@\(startedAtText)" : logFile }

    /// Whether the run exited 0; nil when the daemon recorded no exit code.
    public var succeeded: Bool? { exitCode.map { $0 == 0 } }

    private static func date(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
    }
}

/// `GET /tasks/{name}/log?file=`: at most the last 4 MiB, cut to whole lines.
public struct LeoTaskLog: Decodable, Equatable, Sendable {
    public let file: String
    public let text: String
    /// The log was longer than the daemon reads; this is its end.
    public let truncated: Bool

    public init(file: String, text: String, truncated: Bool = false) {
        self.file = file
        self.text = text
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey { case file, text, truncated }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            file: try container.decodeIfPresent(String.self, forKey: .file) ?? "",
            text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
            truncated: try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        )
    }
}

/// `GET /config/tasks/{name}/prompt`: always the task's configured
/// `prompt_file`, with a revision of its own (the sha256 of its bytes).
public struct LeoTaskPrompt: Decodable, Equatable, Sendable {
    public let revision: String
    public let file: String
    /// The workspace's other prompt files the daemon will serve.
    public let files: [String]
    public let content: String

    public init(revision: String, file: String, files: [String], content: String) {
        self.revision = revision
        self.file = file
        self.files = files
        self.content = content
    }

    enum CodingKeys: String, CodingKey { case revision, file, files, content }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            revision: try container.decode(String.self, forKey: .revision),
            file: try container.decodeIfPresent(String.self, forKey: .file) ?? "",
            files: try container.decodeIfPresent([String].self, forKey: .files) ?? [],
            content: try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        )
    }

    /// The daemon's revision of a prompt file holding `content`.
    public static func revision(of content: String) -> String {
        "sha256:" + SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// `PUT /config/tasks/{name}/prompt`.
public struct LeoTaskPromptWrite: Decodable, Equatable, Sendable {
    public let revision: String
    public let file: String

    public init(revision: String, file: String) {
        self.revision = revision
        self.file = file
    }
}

/// `GET /cron/preview?expr=`.
public struct LeoCronPreview: Decodable, Equatable, Sendable {
    public let valid: Bool
    public let description: String
    public let error: String?

    public init(valid: Bool, description: String, error: String?) {
        self.valid = valid
        self.description = description
        self.error = error
    }

    enum CodingKeys: String, CodingKey { case valid, description, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            valid: try container.decodeIfPresent(Bool.self, forKey: .valid) ?? false,
            description: try container.decodeIfPresent(String.self, forKey: .description) ?? "",
            error: try container.decodeIfPresent(String.self, forKey: .error)
        )
    }
}

/// What a schedule means, or why it doesn't, as the user types it.
public enum LeoCronPreviewResult: Equatable, Sendable {
    case valid(String)
    case invalid(String)
}

/// The daemon's rules for a task's `prompt_file`, checked before a write so a
/// typo is caught early. The daemon stays the judge: it also refuses leo's own
/// config and state files, which only it can recognise.
public enum LeoTaskPromptFile {
    public static func problem(with path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Name the prompt file." }
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == "\\" }) else {
            return "Use plain characters and “/” between folders."
        }
        let travels = trimmed.split(separator: "/", omittingEmptySubsequences: false).contains { ["", ".", ".."].contains($0) }
        return travels ? "A prompt file stays inside the workspace: no “..” or leading “/”." : nil
    }
}
