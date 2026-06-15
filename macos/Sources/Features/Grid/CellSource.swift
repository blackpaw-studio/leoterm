import Foundation

/// The byte source that backs a grid cell's terminal surface.
///
/// - `pty`: a plain terminal cell running the user's `$SHELL` (Ghostty's
///   default PTY path; `command == nil` inherits the configured shell).
/// - `agent`: a Leo agent cell. The surface runs `leo agent attach --cc
///   <name>`, which execs `tmux -L leo -CC attach -t leo-<name>`. The
///   control-mode protocol it emits is consumed by the terminal core's
///   tmux `Viewer`, not displayed verbatim.
///
///   The command is prefixed with `env -u TMUX -u TMUX_PANE` because the
///   control-mode client (tmux / `leo agent attach --cc`) refuses to start
///   when `$TMUX` is set — tmux's session-nesting guard. Without this, when
///   Leo is launched from inside a tmux session the inherited `$TMUX` makes
///   the surface command error out and exit immediately (closing the cell).
///   Clearing it lets the client attach cleanly.
///
/// Both cases resolve to a `Ghostty.SurfaceConfiguration`, so the renderer
/// and input stack stay agnostic to what backs a cell.
enum CellSource: Equatable, Codable {
    case pty
    case agent(name: String)

    /// The env prefix that clears tmux nesting guards before running the
    /// control-mode attach client.
    private static let envPrefix = "/usr/bin/env -u TMUX -u TMUX_PANE"

    /// Absolute path to the `leo` CLI. The attach command MUST use the absolute
    /// path, not bare `leo`: a GUI app's environment does not include
    /// `~/.local/bin` on `$PATH`, so `/usr/bin/env … leo …` would fail with
    /// `env: leo: No such file or directory`. Matches `LeoSocketClient`'s default.
    private static let leoExecutable = NSString(string: "~/.local/bin/leo").expandingTildeInPath

    /// True for cells backed by a Leo agent (carries agent status semantics).
    var isAgent: Bool {
        switch self {
        case .pty: return false
        case .agent: return true
        }
    }

    /// Returns the `leo [--host <host>] agent attach --cc` segment for the
    /// given host. Localhost omits `--host` to stay byte-identical to the
    /// pre-remote-host command.
    private static func leoAttachSegment(host: String, agent name: String) -> String {
        if host == LeoHost.localhostName {
            return "\(leoExecutable) agent attach --cc \(name)"
        } else {
            return "\(leoExecutable) --host \(host) agent attach --cc \(name)"
        }
    }

    /// Returns the per-surface configuration that launches this source.
    ///
    /// - Parameter host: The board host name. Defaults to `LeoHost.localhostName`
    ///   so callers without board context get the same local behaviour as today.
    func surfaceConfiguration(host: String = LeoHost.localhostName) -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        switch self {
        case .pty:
            config.command = nil // inherit $SHELL from global config
        case .agent(let name):
            config.command = "\(Self.envPrefix) \(Self.leoAttachSegment(host: host, agent: name))"
        }
        return config
    }
}

extension CellSource {
    private enum CodingKeys: String, CodingKey { case kind, name }
    private enum Kind: String, Codable { case pty, agent }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pty:
            try c.encode(Kind.pty, forKey: .kind)
        case .agent(let name):
            try c.encode(Kind.agent, forKey: .kind)
            try c.encode(name, forKey: .name)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .pty: self = .pty
        case .agent: self = .agent(name: try c.decode(String.self, forKey: .name))
        }
    }
}
