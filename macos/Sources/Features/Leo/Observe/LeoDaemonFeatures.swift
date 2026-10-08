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
    }

    static let none = LeoDaemonFeatures([])

    let features: Set<Feature>

    init(_ names: [String]) {
        features = Set(names.compactMap(Feature.init(rawValue:)))
    }

    func contains(_ feature: Feature) -> Bool { features.contains(feature) }
}
