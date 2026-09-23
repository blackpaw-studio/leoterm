import Combine
import Foundation

enum LeoUnsavedChangesChoice: Sendable {
    case save
    case discard
    case cancel
}

enum LeoEditorOpenOutcome: Equatable, Sendable {
    case opened
    /// The file was already open: its buffer (edits included) is kept.
    case alreadyOpen
    /// The user cancelled the unsaved-changes prompt, or saving failed.
    case cancelled
}

/// A request to put the caret on a line. Each request is distinct (`id`),
/// so asking for the same line twice still moves the caret back there.
struct LeoEditorReveal: Equatable, Sendable {
    let id = UUID()
    let fileID: LeoEditorFileID
    let line: Int
    let column: Int?
}

/// A window's editor pane: at most one open document, replaced by the next
/// file opened. Replacing or closing a document with unsaved edits asks
/// first (`confirmUnsaved`: Save / Don't Save / Cancel); a Save that fails
/// or conflicts keeps the document. Operations run one at a time.
@MainActor final class LeoEditorPaneModel: ObservableObject {
    static let recentsLimit = 10

    @Published private(set) var document: LeoEditorDocument?
    /// Most recent first, the open document included.
    @Published private(set) var recents: [LeoEditorFileID] = []
    @Published private(set) var reveal: LeoEditorReveal?
    /// Presents the unsaved-changes prompt; the pane's view installs a
    /// sheet. Until then, never discards.
    var confirmUnsaved: @MainActor (LeoEditorDocument) async -> LeoUnsavedChangesChoice = { _ in .cancel }
    /// While the unsaved-changes prompt is up (as opposed to waiting on the
    /// disk or network before or after it).
    private(set) var isConfirming = false

    private let makeAccess: @MainActor (LeoHostID) throws -> any LeoFileAccess
    private let policy: LeoEditorContentPolicy
    private let queue = LeoEditorSerialQueue()

    /// `makeAccess` gives file access for a host (one per document, which
    /// the document releases when it closes).
    init(makeAccess: @escaping @MainActor (LeoHostID) throws -> any LeoFileAccess, policy: LeoEditorContentPolicy = .default) {
        self.makeAccess = makeAccess
        self.policy = policy
    }

    var isOpen: Bool { document != nil }

    /// Opens `fileID`, replacing the current document. The new file is read
    /// before anything is asked, so a file that can't open (the error is
    /// thrown) never costs the user a prompt or their current document.
    @discardableResult
    func open(_ fileID: LeoEditorFileID, line: Int? = nil, column: Int? = nil) async throws -> LeoEditorOpenOutcome {
        try await queue.runThrowing {
            try await self.performOpen(fileID, line: line, column: column)
        }
    }

    /// Closes the document, asking first if it has unsaved edits. `false`
    /// when the user cancelled (or chose Save and it failed).
    @discardableResult
    func close() async -> Bool {
        await queue.run { await self.performClose() }
    }

    /// The window is gone: drops the document without asking (every close
    /// asks first, or keeps a window whose editor has unsaved edits) and
    /// releases its file access -- for a remote host, its `sftp` process.
    func release() async {
        await queue.run { await self.performRelease() }
    }

    /// Drops the document now, unsaved edits and all, without waiting for
    /// anything in flight: its disk or connection isn't answering, and the
    /// user chose to leave anyway. Its access closes in the background,
    /// which fails what's in flight.
    func abandon() {
        guard let document else { return }
        self.document = nil
        reveal = nil
        Task { await document.abandon() }
    }

    /// What `~` means on `host`.
    func homeDirectory(on host: LeoHostID) async throws -> String {
        let access = try makeAccess(host)
        do {
            let home = try await access.homeDirectory()
            await access.close()
            return home
        } catch {
            await access.close()
            throw error
        }
    }

    // MARK: - Operations (serialized)

    private func performOpen(_ fileID: LeoEditorFileID, line: Int?, column: Int?) async throws -> LeoEditorOpenOutcome {
        if let document, document.fileID == fileID {
            requestReveal(fileID, line: line, column: column)
            return .alreadyOpen
        }
        let access = try makeAccess(fileID.host)
        let opened: LeoEditorDocument
        do {
            opened = try await LeoEditorDocument.open(fileID, access: access, policy: policy)
        } catch {
            await access.close()
            throw error
        }
        guard await resolveUnsavedChanges() else {
            await opened.close()
            return .cancelled
        }
        let previous = document
        document = opened
        reveal = nil
        requestReveal(fileID, line: line, column: column)
        remember(fileID)
        await previous?.close()
        return .opened
    }

    private func performClose() async -> Bool {
        guard let document else { return true }
        guard await resolveUnsavedChanges() else { return false }
        self.document = nil
        reveal = nil
        await document.close()
        return true
    }

    private func performRelease() async {
        guard let document else { return }
        self.document = nil
        reveal = nil
        await document.close()
    }

    // MARK: - Helpers

    private func resolveUnsavedChanges() async -> Bool {
        guard let document, document.isDirty else { return true }
        isConfirming = true
        let choice = await confirmUnsaved(document)
        isConfirming = false
        switch choice {
        case .cancel: return false
        case .discard: return true
        case .save: return await document.save() == .saved
        }
    }

    private func requestReveal(_ fileID: LeoEditorFileID, line: Int?, column: Int?) {
        guard let line else { return }
        reveal = LeoEditorReveal(fileID: fileID, line: line, column: column)
    }

    private func remember(_ fileID: LeoEditorFileID) {
        recents = Array(([fileID] + recents.filter { $0 != fileID }).prefix(Self.recentsLimit))
    }
}
