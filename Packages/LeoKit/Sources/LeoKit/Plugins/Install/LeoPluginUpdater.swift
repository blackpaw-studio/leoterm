import Foundation

public enum LeoPluginUpdateError: Error, Equatable, LocalizedError, Sendable {
    /// Not installed, or not a git plugin (bundled and dev ones update with the app or the folder).
    case notUpdatable(String)
    case idChanged(expected: String, found: String)
    /// The plugin changed or was removed since the update was staged.
    case stale

    public var errorDescription: String? {
        switch self {
        case .notUpdatable(let id): "'\(id)' can't be updated from a git source."
        case .idChanged(let expected, let found):
            "The new version declares the id '\(found)' instead of '\(expected)', so it isn't an update of this plugin."
        case .stale: "This plugin changed since the update was prepared. Check for updates again."
        }
    }
}

/// A newer commit that adds permissions. It is on disk, but the registry still
/// pins the old one until `LeoPluginUpdater.approve`.
public struct LeoPluginPendingUpdate: Equatable, Sendable {
    public let result: LeoPluginInstallResult
    public let fromSHA: String
    /// The branch or tag the plugin follows once this is approved.
    public let ref: String
    public let diff: LeoPluginPermissionDiff
    public let request: LeoPluginApprovalRequest
}

public enum LeoPluginUpdateOutcome: Equatable, Sendable {
    case upToDate(sha: String)
    /// The new commit asked for nothing more, so it was swapped in silently.
    case updated(LeoPluginInstallResult)
    case needsApproval(LeoPluginPendingUpdate)
}

/// "Check for updates": resolves the stored ref, stages the new commit with
/// `install(url:sha:)` (the exact commit that was resolved, never the moving
/// ref again), and swaps it in only if it asks for nothing new.
public struct LeoPluginUpdater: Sendable {
    private let store: LeoPluginStore
    private let installer: LeoPluginGitInstaller
    private let root: URL

    public init(store: LeoPluginStore, installer: LeoPluginGitInstaller, root: URL) {
        self.store = store
        self.installer = installer
        self.root = root
    }

    /// Resolves the plugin's ref and stages what it points at. Passing `ref`
    /// switches the plugin to follow that branch or tag instead; it is only
    /// remembered once the commit it resolves to is swapped in, so a ref that
    /// doesn't exist, or a switch that waits on approval, leaves the old one.
    public func check(id: String, ref newRef: String? = nil) async throws -> LeoPluginUpdateOutcome {
        guard let record = store.registry.record(for: id), case .git(let url, let storedRef, let current) = record.source else {
            throw LeoPluginUpdateError.notUpdatable(id)
        }
        let ref = try newRef.map { try Self.normalized($0) } ?? storedRef
        let latest = try await installer.resolve(url: url, ref: ref)
        guard latest != current else {
            if ref != storedRef { try setRef(id, ref, from: current) }
            return .upToDate(sha: current)
        }

        let staged = try await installer.install(url: url, sha: latest)
        guard staged.manifest.id == id else {
            LeoPluginFolders.remove(root: root, id: staged.manifest.id, sha: staged.sha)
            throw LeoPluginUpdateError.idChanged(expected: id, found: staged.manifest.id)
        }
        let diff = LeoPluginPermissionDiff(old: record.approvedPermissions, new: staged.manifest.permissions)
        let request = LeoPluginApprovalRequest(
            id: id, name: staged.manifest.name, version: staged.manifest.version, sha: staged.sha,
            sourceDescription: url, permissions: staged.manifest.permissions, diff: diff, isDev: false)
        let pending = LeoPluginPendingUpdate(result: staged, fromSHA: current, ref: ref, diff: diff, request: request)
        guard diff.isEmpty else { return .needsApproval(pending) }
        try swap(pending)
        return .updated(staged)
    }

    /// The user approved the added permissions.
    public func approve(_ pending: LeoPluginPendingUpdate) throws {
        try swap(pending)
    }

    /// The user declined: drop the staged commit, keep running the old one.
    public func discard(_ pending: LeoPluginPendingUpdate) {
        let id = pending.result.manifest.id
        guard !LeoPluginFolders.isPinned(store.registry, id: id, sha: pending.result.sha) else { return }
        LeoPluginFolders.remove(root: root, id: id, sha: pending.result.sha)
    }

    // MARK: Private

    private func swap(_ pending: LeoPluginPendingUpdate) throws {
        let manifest = pending.result.manifest
        try store.update { registry in
            guard case .git(let url, _, let pinned)? = registry.record(for: manifest.id)?.source, pinned == pending.fromSHA else {
                throw LeoPluginUpdateError.stale
            }
            registry.setSource(manifest.id, .git(url: url, ref: pending.ref, sha: pending.result.sha), version: manifest.version)
            registry.approve(manifest.id, permissions: manifest.permissions)
        }
        LeoPluginFolders.remove(root: root, id: manifest.id, sha: pending.fromSHA)
    }

    /// Same commit under a different name: only the ref changes, nothing to approve.
    private func setRef(_ id: String, _ ref: String, from sha: String) throws {
        try store.update { registry in
            guard let record = registry.record(for: id), case .git(let url, _, let pinned) = record.source, pinned == sha else {
                throw LeoPluginUpdateError.stale
            }
            registry.setSource(id, .git(url: url, ref: ref, sha: pinned), version: record.version)
        }
    }

    /// What `installer.resolve` would validate, applied up front so the stored ref is the trimmed one.
    private static func normalized(_ ref: String) throws -> String {
        switch LeoPluginGitSource.validatedRef(ref) {
        case .success(let name): name
        case .failure(let error): throw error
        }
    }
}
