import Foundation

/// B-288: whether the installed leo can attach to a dispatch subagent
/// writable. leo >= 0.47 takes `dispatch attach --rw`; an older leo (and
/// `--host` remotes older than that) only knows the read-only attach, so
/// that stays the default and the fallback.
enum LeoDispatchAccess: Equatable, Sendable {
    case readOnly
    case readWrite

    /// The extra `dispatch attach` arguments this access needs.
    var attachArguments: [String] {
        switch self {
        case .readOnly: []
        case .readWrite: ["--rw"]
        }
    }
}
