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

    /// Clears the inherited tmux env (so the nesting guard doesn't fire), then
    /// runs the control-mode attach. Trailing space: the agent name follows.
    private static let agentAttachCommand = "/usr/bin/env -u TMUX -u TMUX_PANE leo agent attach --cc"

    /// True for cells backed by a Leo agent (carries agent status semantics).
    var isAgent: Bool {
        switch self {
        case .pty: return false
        case .agent: return true
        }
    }

    /// The per-surface configuration that launches this source.
    var surfaceConfiguration: Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        switch self {
        case .pty:
            config.command = nil // inherit $SHELL from global config
        case .agent(let name):
            config.command = "\(Self.agentAttachCommand) \(name)"
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
