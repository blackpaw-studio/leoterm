import Combine
import LeoKit

/// Where one agent's drawer shell is.
enum LeoDrawerShellState<Surface: AnyObject> {
    /// Nothing has asked for it yet: no process exists.
    case notStarted
    case running(Surface)
    /// The shell ended (status when the surface reported one); Restart starts a new one.
    case exited(status: Int?)
    /// Nothing can be spawned (an old remote leo, a host that isn't connected); the message says why.
    case unavailable(String)
    /// Spawning failed.
    case failed(String)
}

/// One window's drawer shells, one per agent. A shell is made the first time
/// its Terminal body is shown, kept (with its scrollback) while the user
/// switches agents, collapses the pane or changes tabs, and closed when its
/// agent goes, moves or the window closes. Generic over the surface so tests
/// run with a fake; the app's surface is a Ghostty `SurfaceView`.
@MainActor final class LeoDrawerShellPool<Surface: AnyObject> {
    typealias Key = LeoAgentID

    private let make: (LeoDrawerShellLaunch) throws -> Surface
    private let close: (Surface) -> Void
    private var states: [Key: LeoDrawerShellState<Surface>] = [:]
    private let subject = PassthroughSubject<Void, Never>()

    /// Fires after any state changes.
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    init(make: @escaping (LeoDrawerShellLaunch) throws -> Surface, close: @escaping (Surface) -> Void) {
        self.make = make
        self.close = close
    }

    func state(for key: Key) -> LeoDrawerShellState<Surface> { states[key] ?? .notStarted }

    /// The key of the shell this surface belongs to, if it is one of ours and still running.
    func key(of surface: Surface) -> Key? {
        states.first { if case .running(let s) = $0.value { return s === surface } else { return false } }?.key
    }

    /// Starts the agent's shell if it hasn't been started. A running or
    /// exited shell is left as it is (an exited one waits for `restart`); an
    /// unavailable one is decided again, since the host may have connected or
    /// updated since.
    func open(_ key: Key, launch: @autoclosure () -> LeoDrawerShellLaunch) {
        switch state(for: key) {
        case .running, .exited, .failed: return
        case .notStarted, .unavailable: start(key, launch: launch())
        }
    }

    /// Replaces whatever the agent has with a fresh shell.
    func restart(_ key: Key, launch: @autoclosure () -> LeoDrawerShellLaunch) {
        closeSurface(of: key)
        start(key, launch: launch())
    }

    /// The shell ended: close its surface and remember that it exited.
    func markExited(_ key: Key, status: Int?) {
        guard case .running = state(for: key) else { return }
        closeSurface(of: key)
        set(key, .exited(status: status))
    }

    func markExited(surface: Surface, status: Int?) {
        guard let key = key(of: surface) else { return }
        markExited(key, status: status)
    }

    func close(_ key: Key) {
        closeSurface(of: key)
        guard states.removeValue(forKey: key) != nil else { return }
        subject.send()
    }

    func closeAll() {
        for key in Array(states.keys) { closeSurface(of: key) }
        guard !states.isEmpty else { return }
        states = [:]
        subject.send()
    }

    /// Closes the shells of `host`'s agents that `keeping` rejects (the row is
    /// gone or moved); other hosts are untouched.
    func retain(on host: LeoHostID, keeping: (_ name: String) -> Bool) {
        for key in states.keys where key.host == host && !keeping(key.name) { close(key) }
    }

    /// Closes every shell on `host` (the machine was removed).
    func closeAll(on host: LeoHostID) { retain(on: host) { _ in false } }

    // MARK: Private

    private func start(_ key: Key, launch: LeoDrawerShellLaunch) {
        switch launch {
        case .unavailable(let message):
            set(key, .unavailable(message))
        case .local, .remote:
            do {
                set(key, .running(try make(launch)))
            } catch {
                set(key, .failed(error.localizedDescription))
            }
        }
    }

    private func closeSurface(of key: Key) {
        if case .running(let surface) = state(for: key) { close(surface) }
    }

    private func set(_ key: Key, _ next: LeoDrawerShellState<Surface>) {
        states[key] = next
        subject.send()
    }
}

/// Which agents keep their shell when the rows change: a row that is still
/// listed and hasn't moved to another machine. Unlike an editor pane, the row
/// on screen gets no exemption: its shell closes with it.
enum LeoDrawerShellRetention {
    static func keep(row: LeoAgentRow?) -> Bool { row != nil && row?.movedTo == nil }
}
