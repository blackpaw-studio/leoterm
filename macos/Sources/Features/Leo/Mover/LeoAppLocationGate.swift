import Foundation

/// Whether managed features may start after the location check (D7).
enum LeoAppLocationState: Equatable, Sendable {
    case allowed
    /// The user said "Not Now", or the move didn't happen: managed features
    /// stay off and the sidebar shows a banner.
    case declined(LeoMoveReason)
    /// The copy in /Applications was opened and this process is quitting.
    case moved

    var allowsManagedFeatures: Bool { self == .allowed }

    var banner: LeoAppLocationBanner? {
        guard case .declined(let reason) = self else { return nil }
        return LeoAppLocationBanner(reason: reason)
    }
}

/// The sidebar's reminder while managed features are off.
struct LeoAppLocationBanner: Equatable, Sendable {
    let title: String
    let detail: String
    let actionTitle = "Move to Applications…"

    init(reason: LeoMoveReason) {
        title = "Leo isn’t in Applications"
        switch reason {
        case .translocated:
            detail = "macOS is running Leo from a temporary location. Move it to Applications to turn on the background daemon."
        case .readOnlyVolume:
            detail = "Leo is running from a disk image. Move it to Applications to turn on the background daemon."
        case .elsewhere:
            detail = "Move Leo to Applications to turn on the background daemon."
        }
    }
}

/// Runs the launch-time location check: ask once, move on a yes.
@MainActor struct LeoAppLocationGate {
    let location: LeoAppLocation
    let mover: LeoAppMover
    let bundleURL: URL
    let confirmMove: (LeoMoveReason) -> Bool

    func run() async -> LeoAppLocationState {
        guard case .needsMove(let reason) = location else { return .allowed }
        guard confirmMove(reason) else { return .declined(reason) }
        switch await mover.move(bundleURL: bundleURL, reason: reason) {
        case .relaunched: return .moved
        case .manualInstructionsShown, .declinedReplace, .refusedRunning, .failed: return .declined(reason)
        }
    }
}
