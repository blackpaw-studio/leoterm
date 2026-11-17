import AppKit
import LeoKit

/// Shows the upload panel for one workspace pick. The real one is a
/// standalone `NSPanel`; tests inject a fake, so no window opens.
@MainActor protocol LeoBrowserUploadPanelPresenting {
    func show(_ pick: LeoBrowserWorkspacePick) -> any LeoBrowserUploadPanelHandle
}

@MainActor protocol LeoBrowserUploadPanelHandle {
    /// The pick finished: closes the panel without answering it again.
    func dismiss()
}

/// The chooser a page's `<input type=file>` gets: the agent's workspace on
/// its machine (local or over SFTP), with the Mac's own open panel one
/// click away. Folder inputs and agents with no workspace go straight to
/// the Mac panel, so no upload is ever out of reach.
///
/// Chosen files are copied into a private local folder, because WebKit
/// takes only local file URLs; the copies stay until the browser closes
/// (the page may read them only on submit), and the next launch sweeps any
/// a crash left.
@MainActor final class LeoBrowserWorkspaceFilePicker: LeoBrowserFilePicking {
    /// This app's staging root: per bundle id, so a debug build never sweeps
    /// a release build's files.
    nonisolated static var defaultStagingRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LeoBrowserUploads", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Leo", isDirectory: true)
    }

    /// Removes what an earlier run left; called once at launch.
    nonisolated static func sweep(_ root: URL = defaultStagingRoot) {
        try? FileManager.default.removeItem(at: root)
    }

    /// This picker's own folder; `close()` removes it.
    let stagingFolder: URL
    private let host: LeoHostID
    private let agent: String
    private let workspace: @MainActor () -> String?
    private let makeAccess: @MainActor (LeoHostID) throws -> any LeoFileAccess
    private let fallback: any LeoBrowserFilePicking
    private let presenter: any LeoBrowserUploadPanelPresenting

    /// `workspace` is read on every pick (an agent reports it late). By
    /// default the second choice is the Mac's open panel and picks show in
    /// a `LeoBrowserUploadPanel`.
    init(
        host: LeoHostID, agent: String, workspace: @escaping @MainActor () -> String?,
        makeAccess: @escaping @MainActor (LeoHostID) throws -> any LeoFileAccess,
        fallback: (any LeoBrowserFilePicking)? = nil,
        presenter: (any LeoBrowserUploadPanelPresenting)? = nil,
        stagingRoot: URL = defaultStagingRoot
    ) {
        self.host = host
        self.agent = agent
        self.workspace = workspace
        self.makeAccess = makeAccess
        self.fallback = fallback ?? LeoOpenPanelFilePicker()
        self.presenter = presenter ?? LeoBrowserUploadPanelPresenter()
        stagingFolder = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func present(
        _ request: LeoBrowserFilePickRequest,
        completion: @escaping @MainActor ([URL]?) -> Void
    ) -> any LeoBrowserFilePickSession {
        guard !request.allowsDirectories, let workspace = workspace(), workspace.hasPrefix("/") else {
            return fallback.present(request, completion: completion)
        }
        let model = LeoWorkspaceBrowserModel(makeAccess: makeAccess, openFile: { _ in throw CancellationError() })
        let pick = LeoBrowserWorkspacePick(
            request: request, host: host, workspace: workspace, model: model,
            stagingFolder: stagingFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let session = Session(pick: pick)
        let panel = presenter.show(pick)
        pick.onFinish = { [fallback] outcome in
            panel.dismiss()
            Task { await model.close() }
            switch outcome {
            case .chosen(let urls): completion(urls)
            case .cancelled: completion(nil)
            case .fromMac: session.fallback = fallback.present(request, completion: completion)
            }
        }
        pick.open(LeoEditorAgentContext(host: host, name: agent, workspace: workspace))
        return session
    }

    func close() {
        try? FileManager.default.removeItem(at: stagingFolder)
    }

    /// Dismisses whichever chooser is up: the workspace panel, or the Mac
    /// panel it handed over to.
    private final class Session: LeoBrowserFilePickSession {
        let pick: LeoBrowserWorkspacePick
        var fallback: (any LeoBrowserFilePickSession)?

        init(pick: LeoBrowserWorkspacePick) {
            self.pick = pick
        }

        func dismiss() {
            pick.cancel()
            fallback?.dismiss()
        }
    }
}

/// One pick from the workspace: what the upload panel shows and does. It
/// finishes exactly once: with the chosen files' local copies, a hand-off
/// to the Mac's panel, or a cancel.
@MainActor final class LeoBrowserWorkspacePick: ObservableObject {
    enum Outcome: Equatable {
        case chosen([URL])
        case fromMac
        case cancelled
    }

    let request: LeoBrowserFilePickRequest
    let host: LeoHostID
    let workspace: String
    let model: LeoWorkspaceBrowserModel
    /// Chosen files, never folders; at most one unless the input takes several.
    @Published private(set) var selection: [LeoWorkspaceEntry] = []
    /// The file being copied while a choice is under way.
    @Published private(set) var copyingName: String?
    /// Why the last choice couldn't be copied; the panel stays up.
    @Published private(set) var error: String?
    private(set) var isFinished = false
    var onFinish: (@MainActor (Outcome) -> Void)?

    private let stagingFolder: URL
    private var opening: Task<Void, Never>?
    private var copying: Task<Void, Never>?

    init(request: LeoBrowserFilePickRequest, host: LeoHostID, workspace: String, model: LeoWorkspaceBrowserModel, stagingFolder: URL) {
        self.request = request
        self.host = host
        self.workspace = workspace
        self.model = model
        self.stagingFolder = stagingFolder
    }

    var canChoose: Bool { !selection.isEmpty && copyingName == nil && !isFinished }

    /// The workspace as the header names it: `~` for the home folder here,
    /// the machine's name in front over SSH.
    var workspaceLabel: String {
        let path = LeoSFTPServerText.sanitized(workspace)
        switch host {
        case .local: return (path as NSString).abbreviatingWithTildeInPath
        case .remote(let name): return "\(LeoSFTPServerText.sanitized(name)): \(path)"
        }
    }

    func open(_ agent: LeoEditorAgentContext) {
        opening = Task { [model] in await model.open(agent) }
    }

    /// Returns once the workspace's top level has been listed (or failed).
    func waitUntilOpen() async {
        await opening?.value
    }

    /// Folders are dropped; a single-file input keeps only the last file.
    func select(_ entries: [LeoWorkspaceEntry]) {
        let files = entries.filter { !$0.isFolder }
        selection = request.allowsMultipleSelection ? files : Array(files.suffix(1))
        error = nil
    }

    /// Copies the selection into a fresh private folder, keeping each file's
    /// own name, then finishes with those copies. A failure stays in the
    /// panel as `error` and leaves nothing behind.
    func choose() {
        guard canChoose else { return }
        let entries = selection
        error = nil
        copyingName = entries.first?.displayName
        copying = Task { [weak self] in await self?.copy(entries) }
    }

    /// Returns once a choice under way has finished or failed.
    func waitForCopy() async {
        await copying?.value
    }

    func chooseFromMac() {
        finish(.fromMac)
    }

    func cancel() {
        finish(.cancelled)
    }

    private func copy(_ entries: [LeoWorkspaceEntry]) async {
        let attempt = stagingFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var current = entries.first
        do {
            var urls: [URL] = []
            for (index, entry) in entries.enumerated() {
                current = entry
                copyingName = entry.displayName
                let folder = attempt.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                urls.append(try await model.download(entry.path, to: folder.appendingPathComponent(entry.name, isDirectory: false)))
                try Task.checkCancellation()
                guard !isFinished else { throw CancellationError() }
            }
            copyingName = nil
            finish(.chosen(urls))
        } catch {
            try? FileManager.default.removeItem(at: attempt)
            copyingName = nil
            guard !isFinished, !(error is CancellationError) else { return }
            let name = current?.displayName ?? ""
            self.error = "Couldn’t copy “\(name)”: \(LeoWorkspaceBrowserModel.message(for: error))"
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !isFinished else { return }
        isFinished = true
        if case .chosen = outcome {} else { copying?.cancel() }
        onFinish?(outcome)
    }
}
