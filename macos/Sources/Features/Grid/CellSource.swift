/// The byte source that backs a grid cell's terminal surface.
///
/// - `pty`: a plain terminal cell running the user's `$SHELL` (Ghostty's
///   default PTY path; `command == nil` inherits the configured shell).
/// - `agent`: a Leo agent cell. The surface runs `leo agent attach --cc
///   <name>`, which execs `tmux -L leo -CC attach -t leo-<name>`. The
///   control-mode protocol it emits is consumed by the terminal core's
///   tmux `Viewer`, not displayed verbatim.
///
/// Both cases resolve to a `Ghostty.SurfaceConfiguration`, so the renderer
/// and input stack stay agnostic to what backs a cell.
enum CellSource: Equatable {
    case pty
    case agent(name: String)

    private static let agentAttachCommand = "leo agent attach --cc"

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
