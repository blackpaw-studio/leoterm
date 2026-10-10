import Foundation

/// The optional capabilities a daemon advertised in its `hello` (leo >=
/// 0.35). An older daemon sends none; a name this app doesn't know is
/// ignored, so a newer daemon never breaks the decode.
struct LeoDaemonFeatures: Equatable, Sendable {
    enum Feature: String, CaseIterable, Sendable {
        case bridgeTurns = "bridge_turns"
        case attentionReason = "attention_reason"
        case dispatchTree = "dispatch_tree"
        case agentUsage = "agent_usage"
        case agentControl = "agent_control"
        case dispatchAttach = "dispatch_attach"
        case stateSeq = "state_seq"
        case dispatchRemoved = "dispatch_removed"
        case attachDispatchPlacement = "attach_dispatch_placement"
        case dispatchPlacementLive = "dispatch_placement_live"
        case agentEnvironments = "agent_environments"
    }

    static let none = LeoDaemonFeatures([])

    let features: Set<Feature>

    init(_ names: [String]) {
        features = Set(names.compactMap(Feature.init(rawValue:)))
    }

    func contains(_ feature: Feature) -> Bool { features.contains(feature) }

    /// The `agent attach` arguments that ask the daemon to put this viewer's
    /// dispatch subagents in the background (leo >= 0.41), since the sidebar
    /// shows them as rows. Empty on a daemon that doesn't advertise it, so
    /// the command stays as it was.
    var attachPlacementArguments: [String] {
        contains(.attachDispatchPlacement) ? ["--dispatch-placement", "background"] : []
    }
}

/// Features stamped with the host whose daemon advertised them. The stamp
/// travels with the features from the feed connection that received the
/// hello, so a consumer never has to guess which host they came from (the
/// selection can change before the feed's reset lands).
struct LeoHostFeatures: Equatable, Sendable {
    static let none = LeoHostFeatures(host: nil, features: .none)

    let host: LeoHostID?
    let features: LeoDaemonFeatures

    /// These features as they apply to a command aimed at `target`. Another
    /// host's leo may be older, so it gets none.
    func applying(to target: LeoHostID) -> LeoDaemonFeatures {
        target == host ? features : .none
    }
}
