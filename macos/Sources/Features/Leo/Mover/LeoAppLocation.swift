import Foundation

enum LeoBuildKind: Equatable, Sendable {
    case debug
    case release

    static var current: LeoBuildKind {
        #if DEBUG
        .debug
        #else
        .release
        #endif
    }
}

enum LeoMoveReason: Equatable, Sendable {
    /// Gatekeeper runs a quarantined app from a random read-only mount.
    case translocated
    case elsewhere
    case readOnlyVolume
}

/// Where the running bundle lives, which decides whether the bundled daemon
/// may be managed from it (D7): the LaunchAgent and `self_path` name the
/// bundle by path, so a bundle that can move or vanish can't own them.
enum LeoAppLocation: Equatable, Sendable {
    case inApplications
    case needsMove(LeoMoveReason)
    /// Debug builds run from DerivedData and never register (D4).
    case exempt

    static let applicationsPath = "/Applications"
    private static let translocationComponent = "AppTranslocation"

    static func decide(bundleURL: URL, buildKind: LeoBuildKind, isOnReadOnlyVolume: Bool = false) -> LeoAppLocation {
        guard buildKind == .release else { return .exempt }
        let bundle = bundleURL.standardizedFileURL
        if bundle.deletingLastPathComponent().path == applicationsPath { return .inApplications }
        if bundle.pathComponents.contains(translocationComponent) { return .needsMove(.translocated) }
        return .needsMove(isOnReadOnlyVolume ? .readOnlyVolume : .elsewhere)
    }

    var allowsManagedFeatures: Bool {
        guard case .needsMove = self else { return true }
        return false
    }
}
