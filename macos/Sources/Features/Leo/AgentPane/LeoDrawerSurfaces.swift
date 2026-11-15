import AppKit
import Combine
import GhosttyKit
import LeoKit

/// Why a drawer shell could not be made.
enum LeoDrawerSurfaceError: Error, LocalizedError {
    case noTerminalApp, surfaceUnavailable, notLaunchable

    var errorDescription: String? {
        switch self {
        case .noTerminalApp: "No terminal window is available"
        case .surfaceUnavailable: "The terminal surface is unavailable"
        case .notLaunchable: "There is no shell to start"
        }
    }
}

/// A window's drawer shells on real Ghostty surfaces: the pool, the factory
/// that builds a surface from a launch, and the observer that turns "the
/// shell ended" into `pool.markExited`. Glue over AppKit and libghostty,
/// verified by running the app; the choices it makes live in pure code
/// (`LeoDrawerShellLauncher`, `LeoDrawerShellPool`, `LeoDrawerOcclusion`).
@MainActor final class LeoDrawerShells {
    let pool: LeoDrawerShellPool<Ghostty.SurfaceView>
    private let exits: LeoDrawerExitObserver

    /// `app` is read at spawn time: the window's Ghostty app.
    init(app: @escaping @MainActor () -> ghostty_app_t?) {
        let exits = LeoDrawerExitObserver()
        self.exits = exits
        pool = LeoDrawerShellPool(
            make: { launch in
                let surface = try LeoDrawerShells.makeSurface(app: app(), launch: launch)
                exits.watch(surface)
                return surface
            },
            close: { surface in
                exits.forget(surface)
                surface.removeFromSuperview()
            })
        exits.pool = pool
    }

    func closeAll() { pool.closeAll() }

    /// The user's own config (shell, font, theme) with only what the launch
    /// changes: a local shell's working directory, or a remote's command.
    static func makeSurface(app: ghostty_app_t?, launch: LeoDrawerShellLaunch) throws -> Ghostty.SurfaceView {
        guard let app else { throw LeoDrawerSurfaceError.noTerminalApp }
        var configuration = Ghostty.SurfaceConfiguration()
        switch launch {
        case .local(let workingDirectory):
            configuration.workingDirectory = workingDirectory
        case .remote(let command):
            configuration.command = command
            configuration.environmentVariables = [:]
        case .unavailable:
            throw LeoDrawerSurfaceError.notLaunchable
        }
        let view = Ghostty.SurfaceView(app, baseConfig: configuration)
        guard view.surface != nil else { throw LeoDrawerSurfaceError.surfaceUnavailable }
        // libghostty's renderer starts visible; the view records what it was told.
        view.isWindowVisible = true
        return view
    }
}

/// Hears a drawer shell end, by whichever signal comes first: the surface's
/// native exit message (windowed, carries the status), the windowless-exit
/// notification (the drawer is collapsed or on another tab; carries the
/// status), or Ghostty's close request for a finished process (no status of
/// its own; the message's, if one was set). All three arrive from inside
/// libghostty's handling of that surface, so the exit is recorded a turn
/// later, when the surface may be closed. Surfaces that are not the pool's
/// are ignored.
@MainActor final class LeoDrawerExitObserver {
    weak var pool: LeoDrawerShellPool<Ghostty.SurfaceView>?
    private var messageSinks: [ObjectIdentifier: AnyCancellable] = [:]
    private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(forName: Ghostty.Notification.ghosttyCloseSurface, object: nil, queue: .main) { [weak self] note in
                guard note.userInfo?["process_alive"] as? Bool == false,
                      let surface = note.object as? Ghostty.SurfaceView else { return }
                MainActor.assumeIsolated { self?.ended(surface, status: nil) }
            },
            center.addObserver(forName: .leoWindowlessChildExited, object: nil, queue: .main) { [weak self] note in
                guard let surface = note.object as? Ghostty.SurfaceView else { return }
                let status = note.userInfo?[LeoWindowlessChildExit.exitCodeKey] as? Int
                MainActor.assumeIsolated { self?.ended(surface, status: status) }
            },
        ]
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    /// Starts listening for `surface`'s native exit message. Holds the surface weakly: a
    /// strong reference here would keep the pty, and so the shell, alive.
    func watch(_ surface: Ghostty.SurfaceView) {
        messageSinks[ObjectIdentifier(surface)] = surface.$childExitedMessage
            .compactMap { $0 }
            .sink { [weak self, weak surface] message in
                guard let surface else { return }
                self?.ended(surface, status: message.exitCode)
            }
    }

    func forget(_ surface: Ghostty.SurfaceView) {
        messageSinks[ObjectIdentifier(surface)] = nil
    }

    private func ended(_ surface: Ghostty.SurfaceView, status: Int?) {
        // The status is read a turn later so a close request, which has none of its own, can use
        // the message libghostty set just before it.
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let self, let surface, let pool = self.pool else { return }
            pool.markExited(surface: surface, status: status ?? surface.childExitedMessage?.exitCode)
        }
    }
}
