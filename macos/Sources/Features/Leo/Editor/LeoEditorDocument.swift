import Combine
import Foundation

/// A file on a host: what the editor pane opens, and what its recents list.
struct LeoEditorFileID: Hashable, Sendable {
    let host: LeoHostID
    let path: String

    var name: String { (path as NSString).lastPathComponent }
}

/// Whether the file on disk still matches what the buffer is based on.
/// Anything but `.inSync` shows a banner and blocks saving until resolved.
enum LeoEditorDiskState: Equatable, Sendable {
    case inSync
    /// Changed by someone else while the buffer had unsaved edits.
    case changed
    case deleted
}

enum LeoEditorDiskCheck: Equatable, Sendable {
    case unchanged
    /// The buffer was clean, so it now shows the new contents.
    case reloaded
    case conflict
    case deleted
    /// The check itself failed (e.g. disconnected); nothing changed.
    case failed
}

enum LeoEditorSaveOutcome: Equatable, Sendable {
    case saved
    /// Nothing to save.
    case unchanged
    case readOnly
    /// A banner is up: Reload or Keep Mine first.
    case needsResolution
    /// The file changed (or vanished) since it was read; now bannered.
    case conflict
    /// The backend's error message, also in `errorMessage`.
    case failed(String)
}

/// One open file: its buffer, dirty state, and the external-change state
/// machine. The disk is checked only when asked -- when the window becomes
/// key and immediately before saving (the access layer re-checks the
/// conflict token around its atomic write) -- never on a timer. A clean
/// buffer follows the disk silently; a dirty one gets a banner offering
/// Reload or Keep Mine, and can't save until one is chosen.
@MainActor final class LeoEditorDocument: ObservableObject {
    let fileID: LeoEditorFileID
    let language: LeoEditorLanguage
    /// The buffer as of the last `edit` (the view owns the live text, so
    /// keystrokes publish nothing unless the dirty state flips).
    private(set) var text: String
    @Published private(set) var isDirty = false
    @Published private(set) var diskState = LeoEditorDiskState.inSync
    @Published private(set) var readOnlyReason: LeoEditorReadOnlyReason?
    /// The last save or reload failure, until dismissed or superseded.
    @Published private(set) var errorMessage: String?
    /// Bumped whenever `text` is replaced from disk (never by `edit`), so a
    /// view knows to reload its storage.
    @Published private(set) var contentRevision = 0

    /// What the disk holds, as far as the buffer is concerned.
    private enum DiskVersion: Equatable {
        case version(LeoFileVersion)
        case absent
    }

    /// Decodes a file's bytes (`policy.evaluate`, unless a test watches it).
    typealias Evaluate = @Sendable (Data) -> LeoEditorContent

    private let access: any LeoFileAccess
    private let policy: LeoEditorContentPolicy
    private let evaluate: Evaluate
    private let queue = LeoEditorSerialQueue()
    /// The on-disk text the buffer matches when clean; nil after Keep Mine,
    /// when nothing on disk matches it.
    private var savedText: String?
    /// The disk version the buffer is based on (or that Keep Mine accepted
    /// overwriting); saving expects exactly this.
    private var base: DiskVersion
    /// What the disk showed when the banner went up.
    private var observed: DiskVersion?

    var displayName: String { fileID.name }
    var isReadOnly: Bool { readOnlyReason != nil }

    private init(
        fileID: LeoEditorFileID,
        access: any LeoFileAccess,
        policy: LeoEditorContentPolicy,
        evaluate: @escaping Evaluate,
        content: LeoEditorContent,
        version: LeoFileVersion
    ) {
        self.fileID = fileID
        self.access = access
        self.policy = policy
        self.evaluate = evaluate
        language = LeoEditorLanguage(path: fileID.path)
        text = content.text
        savedText = content.text
        readOnlyReason = content.readOnlyReason
        base = .version(version)
    }

    /// Reads the file (failing for folders, missing files and files over
    /// `policy.readLimit`). The caller hands over `access`: `close()`
    /// releases it.
    static func open(
        _ fileID: LeoEditorFileID,
        access: any LeoFileAccess,
        policy: LeoEditorContentPolicy,
        evaluate: Evaluate? = nil
    ) async throws -> LeoEditorDocument {
        let evaluate = evaluate ?? { policy.evaluate($0) }
        let contents = try await access.read(fileID.path, maxBytes: policy.readLimit)
        let content = await decode(contents.data, with: evaluate)
        return LeoEditorDocument(fileID: fileID, access: access, policy: policy, evaluate: evaluate, content: content, version: contents.stat.version)
    }

    /// The view's buffer changed. `revision` is the `contentRevision` the
    /// view shows: an edit of text a reload has since replaced (the view
    /// catches up a run-loop turn later) is ignored, so it can't mark the
    /// buffer dirty with stale text. Ignored for read-only documents too.
    func edit(_ newText: String, revision: Int) {
        guard !isReadOnly, revision == contentRevision else { return }
        text = newText
        let dirty = savedText != newText
        if dirty != isDirty { isDirty = dirty }
    }

    /// Compares the disk with the buffer's base: a clean buffer reloads
    /// silently, a dirty one (or a deleted file) gets a banner. Failures
    /// are quiet -- this runs on every focus, and saving reports them.
    @discardableResult
    func checkDisk() async -> LeoEditorDiskCheck {
        await queue.run { await self.performCheck() }
    }

    @discardableResult
    func save() async -> LeoEditorSaveOutcome {
        await queue.run { await self.performSave() }
    }

    /// Replaces the buffer with the file on disk, clearing any banner.
    func reload() async {
        await queue.run { await self.performReload() }
    }

    /// Resolves a banner in favour of the buffer: the next save overwrites
    /// the version on disk now (or recreates a deleted file), while a
    /// further external change still raises the banner again.
    func keepMine() {
        guard diskState != .inSync, let observed else { return }
        base = observed
        self.observed = nil
        savedText = nil
        isDirty = true
        diskState = .inSync
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Waits for any operation in flight, then releases the file access.
    func close() async {
        await queue.drain()
        await access.close()
    }

    // MARK: - Operations (serialized)

    /// `.reloaded` only when the reload went through; one that failed
    /// leaves the buffer as it was.
    private func performCheck() async -> LeoEditorDiskCheck {
        let current: DiskVersion
        do {
            current = try await diskVersion()
        } catch {
            return .failed
        }
        if current == base {
            diskState = .inSync
            observed = nil
            return .unchanged
        }
        if diskState != .inSync, current == observed { return diskState == .deleted ? .deleted : .conflict }
        if current != .absent, !isDirty {
            guard await performReload() else { return diskState == .deleted ? .deleted : .failed }
            return .reloaded
        }
        flag(current)
        return current == .absent ? .deleted : .conflict
    }

    private func performSave() async -> LeoEditorSaveOutcome {
        guard !isReadOnly else { return .readOnly }
        guard diskState == .inSync else { return .needsResolution }
        guard isDirty else { return .unchanged }
        let snapshot = text
        let expected: LeoFileVersion?
        switch base {
        case .version(let version):
            expected = version
        case .absent:
            // Recreating a deleted file: someone may have recreated it since.
            switch await currentDiskVersion() {
            case .success(.absent): expected = nil
            case .success(let current): flag(current); return .conflict
            case .failure(let error): return fail(error)
            }
        }
        do {
            let written = try await access.write(Data(snapshot.utf8), to: fileID.path, expecting: expected)
            base = .version(written.version)
            savedText = snapshot
            isDirty = text != snapshot
            errorMessage = nil
            return .saved
        } catch LeoFileAccessError.conflict {
            if case .success(let current) = await currentDiskVersion() { flag(current) }
            return .conflict
        } catch {
            return fail(error)
        }
    }

    /// `true` when the buffer now holds the file on disk.
    @discardableResult
    private func performReload() async -> Bool {
        do {
            let contents = try await access.read(fileID.path, maxBytes: policy.readLimit)
            let content = await Self.decode(contents.data, with: evaluate)
            text = content.text
            savedText = content.text
            readOnlyReason = content.readOnlyReason
            base = .version(contents.stat.version)
            observed = nil
            isDirty = false
            diskState = .inSync
            errorMessage = nil
            contentRevision += 1
            return true
        } catch LeoFileAccessError.notFound {
            flag(.absent)
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Helpers

    /// Decoding up to `policy.readLimit` (20 MB) takes a while, so it runs
    /// off the main actor.
    private static func decode(_ data: Data, with evaluate: @escaping Evaluate) async -> LeoEditorContent {
        await Task.detached(priority: .userInitiated) { evaluate(data) }.value
    }

    private func diskVersion() async throws -> DiskVersion {
        do {
            return .version(try await access.stat(fileID.path).version)
        } catch LeoFileAccessError.notFound {
            return .absent
        }
    }

    private func currentDiskVersion() async -> Result<DiskVersion, Error> {
        do {
            return .success(try await diskVersion())
        } catch {
            return .failure(error)
        }
    }

    private func flag(_ current: DiskVersion) {
        observed = current
        diskState = current == .absent ? .deleted : .changed
    }

    private func fail(_ error: Error) -> LeoEditorSaveOutcome {
        let message = error.localizedDescription
        errorMessage = message
        return .failed(message)
    }
}
