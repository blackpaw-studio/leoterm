import Foundation

/// A file or folder in the workspace browser. A symlink is whatever it
/// points at: a link to a folder is a folder, anything else a file.
struct LeoWorkspaceEntry: Hashable, Sendable {
    let name: String
    /// Absolute, on the browser's host.
    let path: String
    let isFolder: Bool

    /// Hidden like Finder hides it: a dotfile.
    var isHidden: Bool { name.hasPrefix(".") }

    /// The name made safe to show: a name is as untrusted as a server's
    /// message (it could add a line or reorder the text around it).
    var displayName: String {
        let clean = LeoSFTPServerText.sanitized(name)
        return clean.isEmpty ? "\u{FFFD}" : clean
    }
}

/// One row of the browser's outline.
enum LeoWorkspaceItem: Hashable, Sendable {
    case entry(LeoWorkspaceEntry)
    /// `parent` is being listed.
    case loading(parent: String)
    /// Why `parent` can't be listed, or that the workspace is empty.
    case message(parent: String, text: String)
}

/// A window's workspace browser (B-005): an agent's workspace tree on the
/// agent's host, through `LeoFileAccess`, so local and SFTP hosts behave
/// alike. Folders are listed only when expanded and again only on
/// `reload()` -- never on a timer. Failures stay inline: a folder that
/// can't be listed shows why in place of its contents, a file that can't
/// be opened shows why in `openError`.
@MainActor final class LeoWorkspaceBrowserModel: ObservableObject {
    struct Root: Equatable, Sendable {
        let host: LeoHostID
        let agent: String
        /// The agent's workspace; nil when it reported none (or not an
        /// absolute one).
        let path: String?
    }

    /// What Browse Agent Files does next.
    enum BrowseStep: Equatable, Sendable {
        case open
        case focus
        case close
    }

    enum Folder: Equatable, Sendable {
        case loading
        /// Folders first, then names in Finder order.
        case loaded([LeoWorkspaceEntry])
        case failed(String)
    }

    static let noWorkspaceMessage = "This agent hasn’t reported a workspace."
    static let emptyMessage = "This folder is empty."
    /// Symlinks in one folder resolved at once, at most.
    static let symlinkStatLimit = 8

    @Published private(set) var root: Root?
    @Published private(set) var folders: [String: Folder] = [:]
    @Published private(set) var expanded: Set<String> = []
    @Published private(set) var showsHiddenFiles = false
    @Published private(set) var openError: String?

    private let makeAccess: @MainActor (LeoHostID) throws -> any LeoFileAccess
    private let openInEditor: @MainActor (LeoEditorFileID) async throws -> LeoEditorOpenOutcome
    private var access: (any LeoFileAccess)?
    /// The latest listing asked for each folder; an older answer arriving
    /// after it (or after the browser was re-rooted) is dropped.
    private var pending: [String: UUID] = [:]
    /// Bumped whenever the root is replaced or closed.
    private var generation = 0

    /// `makeAccess` gives file access for a host (one per root, released
    /// when the browser closes or moves to another agent); `openFile` opens
    /// a file in the window's editor pane.
    init(
        makeAccess: @escaping @MainActor (LeoHostID) throws -> any LeoFileAccess,
        openFile: @escaping @MainActor (LeoEditorFileID) async throws -> LeoEditorOpenOutcome
    ) {
        self.makeAccess = makeAccess
        openInEditor = openFile
    }

    var isOpen: Bool { root != nil }

    /// Where the top level's listing (or its failure) is kept.
    private var rootKey: String { root?.path ?? "" }

    var rootItems: [LeoWorkspaceItem] {
        let items = items(in: rootKey)
        guard items.isEmpty else { return items }
        return [.message(parent: rootKey, text: Self.emptyMessage)]
    }

    /// `folder`'s rows as shown: a placeholder until it's listed, its error
    /// if it couldn't be, else its entries (dotfiles only when shown).
    func items(in folder: String) -> [LeoWorkspaceItem] {
        switch folders[folder] {
        case nil, .loading: [.loading(parent: folder)]
        case let .failed(message): [.message(parent: folder, text: message)]
        case let .loaded(entries): entries.filter { showsHiddenFiles || !$0.isHidden }.map(LeoWorkspaceItem.entry)
        }
    }

    func isExpanded(_ folder: String) -> Bool { expanded.contains(folder) }

    /// Whether the browser is rooted at `agent`'s workspace.
    func shows(_ agent: LeoEditorAgentContext) -> Bool {
        root == Self.root(for: agent)
    }

    /// Browse Agent Files toggles: opens the browser on `agent`, focuses it
    /// when it already shows that agent, and closes it from inside.
    func browseStep(for agent: LeoEditorAgentContext, hasFocus: Bool) -> BrowseStep {
        guard shows(agent) else { return .open }
        return hasFocus ? .close : .focus
    }

    /// Roots the browser at `agent`'s workspace on its host, starting over
    /// (nothing expanded). Already showing that workspace, it reloads
    /// instead, keeping what's expanded.
    ///
    /// The new root and its access are in place before anything suspends,
    /// and every step after a suspension checks it's still current: of
    /// overlapping opens and closes the last one called wins, and each
    /// access is closed by whichever call replaced it.
    func open(_ agent: LeoEditorAgentContext) async {
        let next = Self.root(for: agent)
        if next == root, access != nil {
            await reload()
            return
        }
        let previous = detach()
        let generation = self.generation
        root = next
        if let workspace = next.path {
            do {
                access = try makeAccess(agent.host)
                folders = [workspace: .loading]
            } catch {
                folders = [workspace: .failed(Self.message(for: error))]
            }
        } else {
            folders = ["": .failed(Self.noWorkspaceMessage)]
        }
        await previous?.close()
        guard generation == self.generation, let workspace = next.path else { return }
        await load(workspace)
    }

    /// Lists `folder` the first time it's expanded (or again after it
    /// failed); after that, only `reload()` lists it. Expanded folders
    /// inside it that have no listing (a reload dropped it while `folder`
    /// was collapsed) are listed too.
    func expand(_ folder: String) async {
        guard isOpen else { return }
        expanded.insert(folder)
        switch folders[folder] {
        case nil, .failed: await load(folder)
        case .loading, .loaded: break
        }
        await loadUnlisted(in: folder)
    }

    func collapse(_ folder: String) {
        expanded.remove(folder)
    }

    /// Lists the top level and every expanded folder shown again, keeping
    /// what's expanded. Listings of folders not shown are dropped, so they
    /// are listed afresh when next expanded.
    func reload() async {
        guard isOpen, access != nil else { return }
        let shown = shownFolders(in: rootKey)
        folders = folders.filter { shown.contains($0.key) }
        await withTaskGroup(of: Void.self) { group in
            for folder in shown {
                group.addTask { await self.load(folder) }
            }
        }
    }

    /// Shown again, an expanded dotfolder whose listing a reload dropped
    /// is listed again.
    func toggleHiddenFiles() async {
        showsHiddenFiles.toggle()
        await loadUnlisted(in: rootKey)
    }

    /// Opens `path` in the editor pane (which asks first about unsaved
    /// edits); a failure shows in `openError`.
    func openFile(_ path: String) async {
        guard let root else { return }
        openError = nil
        do {
            _ = try await openInEditor(LeoEditorFileID(host: root.host, path: path))
        } catch {
            openError = Self.message(for: error)
        }
    }

    func dismissOpenError() {
        openError = nil
    }

    /// Hides the browser and releases its file access (for a remote host,
    /// its `sftp` process).
    func close() async {
        await detach()?.close()
    }

    // MARK: - Helpers

    private static func root(for agent: LeoEditorAgentContext) -> Root {
        Root(host: agent.host, agent: agent.name ?? "", path: agent.workspace.flatMap { $0.hasPrefix("/") ? $0 : nil })
    }

    /// Clears the browser and bumps `generation`, so anything suspended
    /// under the old root drops its result. The caller closes the access
    /// returned.
    private func detach() -> (any LeoFileAccess)? {
        let previous = access
        generation += 1
        access = nil
        root = nil
        folders = [:]
        expanded = []
        pending = [:]
        openError = nil
        return previous
    }

    /// Lists every expanded folder shown under `folder` that has no listing,
    /// deepest last (each listing can reveal more).
    private func loadUnlisted(in folder: String) async {
        let generation = self.generation
        var attempted: Set<String> = []
        while generation == self.generation {
            let unlisted = shownFolders(in: folder).filter { folders[$0] == nil && !attempted.contains($0) }
            guard !unlisted.isEmpty else { return }
            attempted.formUnion(unlisted)
            await withTaskGroup(of: Void.self) { group in
                for unlistedFolder in unlisted {
                    group.addTask { await self.load(unlistedFolder) }
                }
            }
        }
    }

    private func load(_ folder: String) async {
        guard let access else { return }
        let generation = self.generation
        let request = UUID()
        pending[folder] = request
        if folders[folder] == nil { folders[folder] = .loading }
        let result: Folder
        do {
            result = .loaded(try await Self.entries(in: folder, access: access))
        } catch {
            result = .failed(Self.message(for: error))
        }
        guard generation == self.generation, pending[folder] == request else { return }
        pending[folder] = nil
        folders[folder] = result
    }

    /// `folder` plus every expanded folder under it that's shown.
    private func shownFolders(in folder: String) -> Set<String> {
        guard case let .loaded(entries) = folders[folder] else { return [folder] }
        return entries
            .filter { $0.isFolder && expanded.contains($0.path) && (showsHiddenFiles || !$0.isHidden) }
            .reduce(into: [folder]) { $0.formUnion(shownFolders(in: $1.path)) }
    }

    /// `folder`'s entries, less any name a server should never send (one
    /// that isn't a single path component). Symlinks are resolved a few at
    /// a time.
    private static func entries(in folder: String, access: any LeoFileAccess) async throws -> [LeoWorkspaceEntry] {
        let listed = try await access.list(folder).filter { isSingleComponent($0.name) }
        let paths = listed.map { folder == "/" ? "/" + $0.name : folder + "/" + $0.name }
        let linkFolders = await symlinkedFolders(listed.indices.filter { listed[$0].kind == .symlink }.map { paths[$0] }, access: access)
        return listed.indices.map { index in
            let entry = listed[index]
            let isFolder = entry.kind == .directory || (entry.kind == .symlink && linkFolders.contains(paths[index]))
            return LeoWorkspaceEntry(name: entry.name, path: paths[index], isFolder: isFolder)
        }.sorted(by: finderOrder)
    }

    private static func isSingleComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// Which of `links` resolve to a folder, stat-ing at most
    /// `symlinkStatLimit` at once. A dangling link is a file (opening it
    /// then says it can't be found).
    private static func symlinkedFolders(_ links: [String], access: any LeoFileAccess) async -> Set<String> {
        await withTaskGroup(of: String?.self) { group in
            var remaining = links[...]
            for link in remaining.prefix(symlinkStatLimit) {
                group.addTask { await isFolder(link, access: access) ? link : nil }
            }
            remaining = remaining.dropFirst(symlinkStatLimit)
            var folders: Set<String> = []
            while let result = await group.next() {
                if let result { folders.insert(result) }
                if let link = remaining.popFirst() {
                    group.addTask { await isFolder(link, access: access) ? link : nil }
                }
            }
            return folders
        }
    }

    private static func isFolder(_ path: String, access: any LeoFileAccess) async -> Bool {
        (try? await access.stat(path).kind) == .directory
    }

    private static func finderOrder(_ lhs: LeoWorkspaceEntry, _ rhs: LeoWorkspaceEntry) -> Bool {
        guard lhs.isFolder == rhs.isFolder else { return lhs.isFolder }
        switch lhs.name.localizedStandardCompare(rhs.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.name < rhs.name
        }
    }

    /// One sanitized line, whatever failed. Only a `LeoFileAccessError`
    /// keeps its curly quotes: it wrote them itself, around names it has
    /// already sanitized (its reason may still hold a line break). Any
    /// other error's text is treated like a server's.
    static func message(for error: Error) -> String {
        guard error is LeoFileAccessError else { return LeoSFTPServerText.sanitized(error.localizedDescription) }
        return LeoSFTPServerText.sanitizedMessage(error.localizedDescription)
    }
}
