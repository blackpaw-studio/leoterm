import Foundation

/// A file an agent asked the user to look at (B-013): the daemon's
/// `file_surfaced` event, and each entry of `/state`'s `surfaced_files`.
/// `agent` + `startedAt` name the incarnation it belongs to (D-074); `id`
/// dedupes. `path` and `reason` are agent-controlled text: shown only
/// through `displayName`/`displayReason`, which sanitize them.
struct LeoSurfacedFile: Equatable, Sendable, Identifiable, Codable {
    let id: String
    let agent: String
    let startedAt: String
    /// As the agent gave it; for display only.
    let path: String
    /// Resolved on the daemon's host; what the editor opens.
    let absPath: String
    /// 1-based; nil when unset (or unusable).
    let line: Int?
    let reason: String?
    let at: String?

    init(
        id: String, agent: String, startedAt: String, path: String, absPath: String, line: Int? = nil, reason: String? = nil,
        at: String? = nil
    ) {
        self.id = id
        self.agent = agent
        self.startedAt = startedAt
        self.path = path
        self.absPath = absPath
        self.line = line
        self.reason = reason
        self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case id, agent, path, line, reason, at
        case startedAt = "started_at"
        case absPath = "abs_path"
    }

    /// Identity and the path to open are required (an absolute `abs_path`:
    /// nothing is resolved against a guessed directory); `line`, `reason`
    /// and `at` of the wrong type or range read as absent.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func required(_ key: CodingKeys) throws -> String {
            let value = try container.decode(String.self, forKey: key)
            guard !value.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "empty")
            }
            return value
        }
        id = try required(.id)
        agent = try required(.agent)
        startedAt = try required(.startedAt)
        path = try required(.path)
        absPath = try required(.absPath)
        guard absPath.hasPrefix("/") else {
            throw DecodingError.dataCorruptedError(forKey: .absPath, in: container, debugDescription: "not absolute")
        }
        line = (try? container.decodeIfPresent(Int.self, forKey: .line)).flatMap { $0 }.flatMap { $0 >= 1 ? $0 : nil }
        reason = (try? container.decodeIfPresent(String.self, forKey: .reason)).flatMap { $0 }
        at = (try? container.decodeIfPresent(String.self, forKey: .at)).flatMap { $0 }
    }

    /// The file name from `path`, sanitized (the whole path when it has no
    /// usable last component).
    var displayName: String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let clean = LeoSFTPServerText.sanitized(name)
        return clean.isEmpty ? LeoSFTPServerText.sanitized(path) : clean
    }

    /// `reason`, sanitized; nil when it says nothing.
    var displayReason: String? {
        reason.map(LeoSFTPServerText.sanitized).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "name — reason", or the name alone. The name is isolated so a
    /// right-to-left one can't reorder the reason around it.
    var menuTitle: String {
        guard let displayReason else { return displayName }
        return "\(LeoSFTPServerText.isolated(displayName)) — \(displayReason)"
    }
}

/// Decodes `/state`'s optional `surfaced_files` without ever failing its
/// parent: a malformed entry is dropped, a malformed array reads as empty.
struct LeoLenientSurfacedFiles: Decodable, Sendable {
    let files: [LeoSurfacedFile]

    init(from decoder: any Decoder) throws {
        guard var container = try? decoder.unkeyedContainer() else {
            files = []
            return
        }
        var files: [LeoSurfacedFile] = []
        while !container.isAtEnd {
            if let file = try? container.decode(LeoSurfacedFile.self) {
                files.append(file)
            } else {
                // Skips the bad element so the next one is read.
                _ = try? container.decode(LeoSkippedValue.self)
            }
        }
        self.files = files
    }
}

/// Consumes one JSON value of any shape (reads nothing, so never fails).
private struct LeoSkippedValue: Decodable {
    init(from decoder: any Decoder) throws {}
}

/// The row's quiet pending-files indicator: a document glyph, the count,
/// and a tooltip listing each file with its reason (all sanitized).
struct LeoSurfacedFilesIndicator: Equatable {
    static let symbolName = "doc.text"

    let countText: String
    let tooltip: String
    let accessibilityLabel: String

    /// nil when nothing is pending. `pending` is newest last; the tooltip
    /// lists newest first.
    init?(pending: [LeoSurfacedFile]) {
        guard !pending.isEmpty else { return nil }
        countText = "\(pending.count)"
        tooltip = pending.reversed().map(\.menuTitle).joined(separator: "\n")
        accessibilityLabel = pending.count == 1 ? "1 surfaced file" : "\(pending.count) surfaced files"
    }
}
