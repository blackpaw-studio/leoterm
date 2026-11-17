import Foundation

/// One download in an agent browser: what `browser_downloads` lists and the
/// pane's download strip shows.
public struct LeoBrowserDownload: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// The browser is fetching it into a private local temp file.
        case downloading(receivedBytes: Int64, expectedBytes: Int64?)
        /// Fetched; being written into the agent's workspace.
        case saving
        case finished(LeoBrowserSavedDownload)
        /// The whole user-facing sentence, saying whether anything was saved.
        case failed(String)
    }

    /// Counts up from 1 within one browser.
    public let id: Int
    /// The sanitised name it is saved under, before any clash numbering.
    public let name: String
    /// Where it came from, in the web view's own (local) terms.
    public let sourceURL: URL?
    public let state: State

    public init(id: Int, name: String, sourceURL: URL?, state: State) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.state = state
    }

    func with(state: State) -> Self {
        Self(id: id, name: name, sourceURL: sourceURL, state: state)
    }
}

/// A download written into the workspace.
public struct LeoBrowserSavedDownload: Equatable, Sendable {
    /// Absolute, on the agent's machine.
    public let path: String
    /// Relative to the workspace, e.g. `downloads/x 2.pdf`.
    public let workspacePath: String
    public let size: UInt64

    public init(path: String, workspacePath: String, size: UInt64) {
        self.path = path
        self.workspacePath = workspacePath
        self.size = size
    }

    /// The file name it was saved under (numbered after a clash).
    public var name: String { (path as NSString).lastPathComponent }
}

/// The name a download is saved under: WebKit's suggestion (the server's
/// `Content-Disposition` or the URL's last component) made into one safe
/// path component.
public enum LeoBrowserDownloadName {
    public static let fallback = "download"
    /// Leaves room for a clash number and the staging name's affixes.
    public static let maximumBytes = 200
    /// The longest extension kept whole when a name is cut.
    private static let maximumExtensionBytes = 16

    /// Separators and control or format characters (bidi overrides
    /// included) become `_`; leading dots go, so nothing is hidden;
    /// whitespace is trimmed; an empty result is `download`. Over-long
    /// names are cut on a character boundary, keeping a short extension.
    public static func sanitized(_ suggested: String) -> String {
        let replaced = String(String.UnicodeScalarView(suggested.unicodeScalars.map { scalar in
            isUnsafe(scalar) ? "_" : scalar
        }))
        let trimmed = replaced.trimmingCharacters(in: .whitespaces)
        let visible = String(trimmed.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
        let name = visible.isEmpty ? fallback : visible
        return LeoFileName.isSafeComponent(name) ? cut(name) : fallback
    }

    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "/" || scalar == "\\" || scalar == "\0" || CharacterSet.controlCharacters.contains(scalar)
    }

    private static func cut(_ name: String) -> String {
        guard name.utf8.count > maximumBytes else { return name }
        let pathExtension = (name as NSString).pathExtension
        let keepsExtension = !pathExtension.isEmpty && pathExtension.utf8.count <= maximumExtensionBytes
        let suffix = keepsExtension ? "." + pathExtension : ""
        let stem = keepsExtension ? (name as NSString).deletingPathExtension : name
        return prefix(of: stem, bytes: maximumBytes - suffix.utf8.count) + suffix
    }

    private static func prefix(of text: String, bytes limit: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            let size = character.utf8.count
            guard used + size <= limit else { break }
            result.append(character)
            used += size
        }
        return result
    }
}

/// Why a download couldn't be saved into the workspace.
public enum LeoBrowserDownloadSaveError: Error, Equatable, Sendable {
    /// The agent has no absolute workspace path (a dispatch, or not reported yet).
    case noWorkspace
    /// Every numbered name up to the limit is taken.
    case noFreeName(String)
    /// The connection went before the file was published: it isn't there.
    case lostConnection
    /// The connection went while publishing: it may or may not be there.
    case uncertain
    /// The downloaded temp file couldn't be read back.
    case unreadable
    case file(LeoFileAccessError)

    /// One sentence, in the app's words.
    public var message: String {
        switch self {
        case .noWorkspace: "This agent has no workspace to save downloads in."
        case .noFreeName(let name): "Too many files named “\(name)” are already in \(LeoBrowserDownloadSaver.folderName)/."
        case .lostConnection: "The connection to the machine was lost."
        case .uncertain: "The connection was lost while saving; check \(LeoBrowserDownloadSaver.folderName)/ before trying again."
        case .unreadable: "The downloaded file couldn’t be read back."
        case .file(let error): error.localizedDescription
        }
    }

    /// Whether the file may have been saved after all.
    public var mayHaveSaved: Bool { self == .uncertain }
}

/// Writes finished downloads into `<workspace>/downloads/` through the
/// machine's file backend (local filesystem or SFTP), so it works the same
/// on every machine. A save never overwrites (a clash gets "name 2.ext")
/// and never leaves a partial file: the bytes are staged in a hidden
/// sibling and published atomically. When a connection drops mid-save the
/// staging can stay behind; the next save, on a fresh connection, removes
/// it first. That list is in memory only: if the app quits first, a hidden
/// `.name.leo-*.tmp` can remain (accepted).
public actor LeoBrowserDownloadSaver {
    /// A fresh file access for the browser's machine; each save closes its own.
    public typealias MakeAccess = @Sendable () async throws -> any LeoFileAccess

    public static let folderName = "downloads"
    /// Names tried, the plain one included, before giving up.
    public static let numberedNameLimit = 100

    private let makeAccess: MakeAccess
    private var leftoverStagings: Set<String> = []

    public init(makeAccess: @escaping MakeAccess) {
        self.makeAccess = makeAccess
    }

    /// Saves the local file at `file`, streamed, never read whole.
    public func save(file: URL, suggestedName: String, workspace: String?) async throws -> LeoBrowserSavedDownload {
        let source: LeoFileDescriptorSource
        do {
            source = try LeoFileDescriptorSource(path: file.path)
        } catch {
            throw LeoBrowserDownloadSaveError.unreadable
        }
        return try await save(source, suggestedName: suggestedName, workspace: workspace)
    }

    /// Saves `source` as `suggestedName` (sanitised), or the first free
    /// numbered name, in `<workspace>/downloads/`, creating that folder.
    public func save(_ source: any LeoFileByteSource, suggestedName: String, workspace: String?) async throws -> LeoBrowserSavedDownload {
        guard let workspace, workspace.hasPrefix("/"), !workspace.contains("\0") else { throw LeoBrowserDownloadSaveError.noWorkspace }
        let access = try await mapped { try await makeAccess() }
        do {
            let saved = try await save(source, as: LeoBrowserDownloadName.sanitized(suggestedName), in: workspace, access: access)
            await access.close()
            return saved
        } catch {
            await access.close()
            throw error
        }
    }

    private func save(_ source: any LeoFileByteSource, as name: String, in workspace: String, access: any LeoFileAccess) async throws -> LeoBrowserSavedDownload {
        await removeLeftovers(with: access)
        let folder = (workspace as NSString).appendingPathComponent(Self.folderName)
        let taken = try await mapped {
            guard try await access.stat(workspace).kind == .directory else { throw LeoFileAccessError.notADirectory(path: workspace) }
            try await access.ensureDirectory(folder)
            return Set(try await access.list(folder).map(\.name))
        }
        for number in 1...Self.numberedNameLimit {
            let candidate = number == 1 ? name : LeoFileName.numbered(name, number)
            guard !taken.contains(candidate) else { continue }
            let path = (folder as NSString).appendingPathComponent(candidate)
            if let stat = try await create(path, from: source, access: access) {
                return LeoBrowserSavedDownload(path: path, workspacePath: Self.folderName + "/" + candidate, size: stat.size)
            }
        }
        throw LeoBrowserDownloadSaveError.noFreeName(name)
    }

    /// The created file's stat, or nil when the name turned out to be taken.
    private func create(_ path: String, from source: any LeoFileByteSource, access: any LeoFileAccess) async throws -> LeoFileStat? {
        let staging = LeoFileName.stagingPath(for: path)
        do {
            return try await access.create(at: path, from: source, staging: staging)
        } catch LeoFileAccessError.conflict {
            return nil
        } catch LeoFileAccessError.disconnected, LeoFileAccessError.closed {
            leftoverStagings.insert(staging)
            throw LeoBrowserDownloadSaveError.lostConnection
        } catch LeoFileAccessError.indeterminate {
            leftoverStagings.insert(staging)
            throw LeoBrowserDownloadSaveError.uncertain
        } catch let error as LeoFileAccessError {
            throw LeoBrowserDownloadSaveError.file(error)
        }
    }

    /// Best effort: a staging that can't be removed yet stays listed.
    private func removeLeftovers(with access: any LeoFileAccess) async {
        for staging in leftoverStagings {
            if (try? await access.removeStaging(staging)) != nil { leftoverStagings.remove(staging) }
        }
    }

    /// File-access failures become save errors; a dropped connection is `.lostConnection`.
    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch LeoFileAccessError.disconnected, LeoFileAccessError.closed {
            throw LeoBrowserDownloadSaveError.lostConnection
        } catch let error as LeoFileAccessError {
            throw LeoBrowserDownloadSaveError.file(error)
        }
    }
}

/// One agent browser's downloads for this app session, newest first: the
/// browser reports each step, and finished downloads are saved into the
/// agent's workspace here. Not persisted.
@MainActor public final class LeoBrowserDownloads {
    /// The most ended downloads kept; the oldest drop off when a new one
    /// starts. A download still fetching or saving is never dropped.
    public static let historyLimit = 50

    public private(set) var entries: [LeoBrowserDownload] = []

    private let saver: LeoBrowserDownloadSaver
    private let workspace: @MainActor () -> String?
    private let removeFile: @Sendable (URL) -> Void
    private var nextID = 1
    private var handlers: [UUID: @MainActor () -> Void] = [:]

    /// `workspace` is read when a download finishes; `removeFile` deletes
    /// the browser's local temp file once it is no longer needed.
    public init(
        saver: LeoBrowserDownloadSaver, workspace: @escaping @MainActor () -> String?,
        removeFile: @escaping @Sendable (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }
    ) {
        self.saver = saver
        self.workspace = workspace
        self.removeFile = removeFile
    }

    /// A download started; returns its id.
    @discardableResult
    public func begin(suggestedName: String, sourceURL: URL?) -> Int {
        let id = nextID
        nextID += 1
        let entry = LeoBrowserDownload(
            id: id, name: LeoBrowserDownloadName.sanitized(suggestedName), sourceURL: sourceURL,
            state: .downloading(receivedBytes: 0, expectedBytes: nil)
        )
        entries = Self.trimmed([entry] + entries)
        changed()
        return id
    }

    /// Ignored once the fetch has ended: a progress report can arrive late.
    public func progress(_ id: Int, receivedBytes: Int64, expectedBytes: Int64?) {
        guard case .downloading? = entries.first(where: { $0.id == id })?.state else { return }
        update(id, .downloading(receivedBytes: receivedBytes, expectedBytes: expectedBytes))
    }

    /// The fetch failed or was cancelled; the browser has already deleted
    /// its temp file.
    public func fail(_ id: Int, reason: String) {
        let cause = LeoSFTPServerText.sanitized(reason)
        update(id, .failed("The download failed: \(Self.sentence(cause)) \(Self.nothingSaved)"))
    }

    /// The fetch finished into `file`: saves it into the workspace, then
    /// removes `file` whatever happened.
    public func complete(_ id: Int, file: URL) async {
        guard let entry = entries.first(where: { $0.id == id }) else { return removeFile(file) }
        update(id, .saving)
        do {
            let saved = try await saver.save(file: file, suggestedName: entry.name, workspace: workspace())
            update(id, .finished(saved))
        } catch let error as LeoBrowserDownloadSaveError {
            update(id, .failed(error.mayHaveSaved ? error.message : "\(error.message) \(Self.nothingSaved)"))
        } catch {
            update(id, .failed("\(LeoSFTPServerText.sanitized(error.localizedDescription)) \(Self.nothingSaved)"))
        }
        removeFile(file)
    }

    /// Handlers run after every change; the returned closure removes one.
    public func observe(_ handler: @escaping @MainActor () -> Void) -> () -> Void {
        let id = UUID()
        handlers[id] = handler
        return { [weak self] in self?.handlers[id] = nil }
    }

    // MARK: - Helpers

    private static let nothingSaved = "Nothing was saved."

    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return "unknown error." }
        return ".!?…".contains(last) ? text : text + "."
    }

    /// Every active download, then the newest ended ones up to the limit.
    private static func trimmed(_ entries: [LeoBrowserDownload]) -> [LeoBrowserDownload] {
        let room = max(historyLimit - entries.filter(isActive).count, 0)
        let keptEnded = Set(entries.filter { !isActive($0) }.prefix(room).map(\.id))
        return entries.filter { isActive($0) || keptEnded.contains($0.id) }
    }

    private static func isActive(_ download: LeoBrowserDownload) -> Bool {
        switch download.state {
        case .downloading, .saving: true
        case .finished, .failed: false
        }
    }

    private func update(_ id: Int, _ state: LeoBrowserDownload.State) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries = entries.map { $0.id == id ? $0.with(state: state) : $0 }
        changed()
    }

    private func changed() {
        handlers.values.forEach { $0() }
    }
}
