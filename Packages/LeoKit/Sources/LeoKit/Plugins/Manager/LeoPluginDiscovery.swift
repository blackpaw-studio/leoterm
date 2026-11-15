import Foundation

/// A plugin folder found on disk: valid, or refused with the reason.
public struct LeoPluginCandidate: Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        case bundled
        case installed(sha: String)
        case dev

        /// Lower wins when two folders claim one id: dev, then installed, then bundled.
        var priority: Int {
            switch self {
            case .dev: 0
            case .installed: 1
            case .bundled: 2
            }
        }
    }

    public let origin: Origin
    public let directory: URL
    public let manifest: LeoPluginManifest?
    public let refusal: String?
}

public struct LeoPluginDiscoveryResult: Equatable, Sendable {
    /// One entry per plugin id (the winner), plus every refused folder.
    public let plugins: [LeoPluginCandidate]
    /// Valid folders that lost to a higher-priority copy of the same id.
    public let shadowed: [LeoPluginCandidate]

    public func plugin(id: String) -> LeoPluginCandidate? { plugins.first { $0.manifest?.id == id } }
}

/// Finds plugin folders in the three places they live. Pure over the file
/// system; every manifest goes through the same validator as an install.
public enum LeoPluginDiscovery {
    /// - `bundledRoot`: `Bundle.main.resourceURL/Plugins`, one `<id>/` folder per plugin.
    /// - `installedRoot`: `<root>`, holding `<id>/<sha>/`; only the registry's pinned
    ///   `installed` shas are scanned, so a staged update that isn't approved never runs.
    /// - `devFolders`: registered in place.
    public static func discover(
        bundledRoot: URL?, installedRoot: URL, installed: [String: String], devFolders: [URL]
    ) -> LeoPluginDiscoveryResult {
        var found: [LeoPluginCandidate] = []
        if let bundledRoot {
            found += subfolders(of: bundledRoot).map { candidate($0, origin: .bundled, expectedID: $0.lastPathComponent) }
        }
        for (id, sha) in installed.sorted(by: { $0.key < $1.key }) {
            let folder = installedRoot.appendingPathComponent(id).appendingPathComponent(sha)
            found.append(candidate(folder, origin: .installed(sha: sha), expectedID: id))
        }
        found += devFolders.map { candidate($0, origin: .dev, expectedID: nil) }
        return resolve(found)
    }

    // MARK: Private

    private static func candidate(_ directory: URL, origin: LeoPluginCandidate.Origin, expectedID: String?) -> LeoPluginCandidate {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return refused(directory, origin, "the plugin folder is missing")
        }
        switch LeoPluginBundleFile.manifest(in: directory) {
        case .refused(let reason):
            return refused(directory, origin, reason)
        case .valid(let manifest):
            if let expectedID, manifest.id != expectedID {
                return refused(directory, origin, "its manifest id '\(manifest.id)' doesn't match the folder '\(expectedID)'")
            }
            return LeoPluginCandidate(origin: origin, directory: directory, manifest: manifest, refusal: nil)
        }
    }

    private static func refused(_ directory: URL, _ origin: LeoPluginCandidate.Origin, _ reason: String) -> LeoPluginCandidate {
        LeoPluginCandidate(origin: origin, directory: directory, manifest: nil, refusal: reason)
    }

    private static func resolve(_ found: [LeoPluginCandidate]) -> LeoPluginDiscoveryResult {
        var winners: [String: LeoPluginCandidate] = [:]
        var shadowed: [LeoPluginCandidate] = []
        for entry in found {
            guard let id = entry.manifest?.id else { continue }
            if let current = winners[id] {
                if entry.origin.priority < current.origin.priority {
                    shadowed.append(current)
                    winners[id] = entry
                } else {
                    shadowed.append(entry)
                }
            } else {
                winners[id] = entry
            }
        }
        let refusals = found.filter { $0.manifest == nil }
        let plugins = winners.values.sorted { ($0.manifest?.id ?? "") < ($1.manifest?.id ?? "") } + refusals
        return LeoPluginDiscoveryResult(plugins: plugins, shadowed: shadowed)
    }

    private static func subfolders(of folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
