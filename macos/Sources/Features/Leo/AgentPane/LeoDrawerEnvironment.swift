import Foundation
import LeoKit

/// What the Terminal tab needs from its window: the shells, how an agent's
/// shell launches (a function of the machine's current features and
/// connection), and how to hand the keyboard back to the agent's main view.
@MainActor final class LeoDrawerEnvironment {
    let shells: LeoDrawerShells
    let launch: @MainActor (LeoAgentIdentity) -> LeoDrawerShellLaunch
    let focusMain: @MainActor () -> Void

    init(
        shells: LeoDrawerShells,
        launch: @escaping @MainActor (LeoAgentIdentity) -> LeoDrawerShellLaunch,
        focusMain: @escaping @MainActor () -> Void
    ) {
        self.shells = shells
        self.launch = launch
        self.focusMain = focusMain
    }

    var pool: LeoDrawerShellPool<Ghostty.SurfaceView> { shells.pool }

    static func key(for identity: LeoAgentIdentity) -> LeoAgentID { LeoAgentID(host: identity.host, name: identity.name) }

    /// Whether `view` is one of this window's drawer shells.
    func owns(_ view: AnyObject?) -> Bool {
        guard let surface = view as? Ghostty.SurfaceView else { return false }
        return pool.key(of: surface) != nil
    }
}
