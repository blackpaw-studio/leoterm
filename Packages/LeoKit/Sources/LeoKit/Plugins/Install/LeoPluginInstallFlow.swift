import Foundation

/// A git install that is on disk but not yet approved. Nothing runs until `LeoPluginInstallFlow.confirm`.
public struct LeoPluginPendingInstall: Equatable, Sendable {
    public let result: LeoPluginInstallResult
    public let request: LeoPluginApprovalRequest
}

/// A dev folder that is validated but not yet approved.
public struct LeoPluginPendingDev: Equatable, Sendable {
    public let manifest: LeoPluginManifest
    public let folder: URL
    public let request: LeoPluginApprovalRequest
}

/// Install and "Load local folder…" in two steps, so the approval sheet sits
/// between "files on disk" and "plugin registered": `stage` downloads and
/// validates, `confirm` registers (and so enables) it, `cancel` removes it.
public struct LeoPluginInstallFlow: Sendable {
    private let store: LeoPluginStore
    private let installer: LeoPluginGitInstaller
    private let root: URL

    public init(store: LeoPluginStore, installer: LeoPluginGitInstaller, root: URL) {
        self.store = store
        self.installer = installer
        self.root = root
    }

    // MARK: Git

    public func stage(url: String, ref: String) async throws -> LeoPluginPendingInstall {
        let result = try await installer.install(url: url, ref: ref)
        let request = LeoPluginApprovalRequest(
            id: result.manifest.id, name: result.manifest.name, version: result.manifest.version, sha: result.sha,
            sourceDescription: result.url, permissions: result.manifest.permissions, diff: nil, isDev: false)
        return LeoPluginPendingInstall(result: result, request: request)
    }

    /// The user approved: register the plugin with exactly the permissions shown.
    public func confirm(_ pending: LeoPluginPendingInstall) throws {
        let manifest = pending.result.manifest
        let previous = store.registry.record(for: manifest.id)
        try store.update {
            $0.registerInstalled(manifest, url: pending.result.url, ref: pending.result.ref, sha: pending.result.sha)
        }
        // A reinstall from the same source at a new commit replaces the old copy.
        if case .git(_, _, let oldSHA)? = previous?.source, oldSHA != pending.result.sha {
            LeoPluginFolders.remove(root: root, id: manifest.id, sha: oldSHA)
        }
    }

    /// The user declined. A copy the registry already pins (a reinstall of the
    /// live commit) is left alone.
    public func cancel(_ pending: LeoPluginPendingInstall) throws {
        let id = pending.result.manifest.id
        guard !LeoPluginFolders.isPinned(store.registry, id: id, sha: pending.result.sha) else { return }
        LeoPluginFolders.remove(root: root, id: id, sha: pending.result.sha)
    }

    // MARK: Dev

    /// Validates a local folder in place. A dev folder can't take an id that a
    /// git or bundled plugin owns (they'd share its Keychain items).
    public func stageDev(folder: URL) throws -> LeoPluginPendingDev {
        let manifest: LeoPluginManifest
        switch LeoPluginBundleFile.manifest(in: folder) {
        case .refused(let reason): throw LeoPluginInstallError.manifestRefused(reason)
        case .valid(let valid): manifest = valid
        }
        do {
            _ = try LeoPluginBundleFile.readMain(manifest.main, in: folder)
        } catch let refusal as LeoPluginBundleFile.Refusal {
            throw LeoPluginInstallError.mainUnusable(refusal.message)
        }
        switch store.registry.record(for: manifest.id)?.source {
        case .git(let url, _, _)?: throw LeoPluginInstallError.idTakenBySource(id: manifest.id, source: url)
        case .bundled?: throw LeoPluginInstallError.idReserved(id: manifest.id)
        case .dev(let path)? where path != folder.path: throw LeoPluginInstallError.idReserved(id: manifest.id)
        case .dev?, nil: break
        }
        let request = LeoPluginApprovalRequest(
            id: manifest.id, name: manifest.name, version: manifest.version, sha: nil,
            sourceDescription: folder.path, permissions: manifest.permissions, diff: nil, isDev: true)
        return LeoPluginPendingDev(manifest: manifest, folder: folder, request: request)
    }

    public func confirmDev(_ pending: LeoPluginPendingDev) throws {
        try store.update { $0.registerDev(pending.manifest, path: pending.folder.path) }
    }
}
