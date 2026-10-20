import Foundation

/// Reads, writes and removes `managed.json` through the file-system seam.
struct LeoMarkerStore: Sendable {
    /// leo ignores a marker that group or world can rewrite: its `self_path`
    /// ends up in hooks that agents execute.
    static let markerMode: mode_t = 0o600
    static let stateDirectoryMode: mode_t = 0o700

    let paths: LeoInstallPaths
    let fileSystem: any LeoFileSystem
    let bundleID: String

    func read() -> LeoMarkerState {
        let url = paths.markerURL
        switch fileSystem.kind(at: url) {
        case .absent:
            return .absent
        case .directory, .symlink:
            return .invalid("marker is not a regular file")
        case .file:
            break
        }
        if let mode = fileSystem.mode(at: url), mode & 0o022 != 0 {
            return .invalid("marker is group- or world-writable (\(String(format: "0%o", mode)))")
        }
        do {
            return LeoManagedMarker.decode(try fileSystem.read(url), ownBundleID: bundleID)
        } catch {
            return .invalid("cannot read marker: \(error)")
        }
    }

    func write(_ marker: LeoManagedMarker) throws {
        let data = try marker.encoded()
        if fileSystem.kind(at: paths.stateDirectory) == .absent {
            try fileSystem.createDirectory(at: paths.stateDirectory, mode: Self.stateDirectoryMode)
        }
        try fileSystem.writeAtomically(data, to: paths.markerURL, mode: Self.markerMode)
    }

    /// Unlinks only `managed.json`; a missing marker is not an error.
    func remove() throws {
        guard fileSystem.kind(at: paths.markerURL) != .absent else { return }
        try fileSystem.remove(paths.markerURL)
    }
}
