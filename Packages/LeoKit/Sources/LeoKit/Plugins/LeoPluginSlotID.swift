import Foundation

/// The two renders of a pane: the one-line `summary` in the collapsed tab bar
/// and the expanded `body`.
public enum LeoPluginPanePart: String, Codable, Hashable, Sendable {
    case summary, body
}

/// Address of one rendered surface. The app puts the slot in each event it
/// sends, and plugin code hands it back verbatim to `leo.render`, so a
/// plugin never has to build one (the router still checks it against the
/// manifest's contributions).
///
/// Wire form: `{"kind": "view"|"accessory"|"section"|"palette"|"pane", ...}`.
public enum LeoPluginSlotID: Codable, Hashable, Sendable {
    case view(viewID: String, agent: LeoPluginAgentRef)
    case accessory(id: String, agent: LeoPluginAgentRef)
    case section(id: String)
    case palette(commandID: String)
    /// One part of a plugin's pane under an agent's terminal/chat view.
    case pane(id: String, part: LeoPluginPanePart, agent: LeoPluginAgentRef)

    private enum CodingKeys: String, CodingKey {
        case kind, viewID, id, commandID, agent, part
    }

    /// Stable string for dictionary keys and logs.
    public var key: String {
        switch self {
        case .view(let viewID, let agent): "view:\(viewID):\(agent.machine):\(agent.name)"
        case .accessory(let id, let agent): "accessory:\(id):\(agent.machine):\(agent.name)"
        case .section(let id): "section:\(id)"
        case .palette(let commandID): "palette:\(commandID)"
        case .pane(let id, let part, let agent): "pane:\(id):\(part.rawValue):\(agent.machine):\(agent.name)"
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "view":
            self = .view(
                viewID: try container.decode(String.self, forKey: .viewID),
                agent: try container.decode(LeoPluginAgentRef.self, forKey: .agent))
        case "accessory":
            self = .accessory(
                id: try container.decode(String.self, forKey: .id),
                agent: try container.decode(LeoPluginAgentRef.self, forKey: .agent))
        case "section":
            self = .section(id: try container.decode(String.self, forKey: .id))
        case "palette":
            self = .palette(commandID: try container.decode(String.self, forKey: .commandID))
        case "pane":
            self = .pane(
                id: try container.decode(String.self, forKey: .id),
                part: try container.decode(LeoPluginPanePart.self, forKey: .part),
                agent: try container.decode(LeoPluginAgentRef.self, forKey: .agent))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown slot kind \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .view(let viewID, let agent):
            try container.encode("view", forKey: .kind)
            try container.encode(viewID, forKey: .viewID)
            try container.encode(agent, forKey: .agent)
        case .accessory(let id, let agent):
            try container.encode("accessory", forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(agent, forKey: .agent)
        case .section(let id):
            try container.encode("section", forKey: .kind)
            try container.encode(id, forKey: .id)
        case .palette(let commandID):
            try container.encode("palette", forKey: .kind)
            try container.encode(commandID, forKey: .commandID)
        case .pane(let id, let part, let agent):
            try container.encode("pane", forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(part, forKey: .part)
            try container.encode(agent, forKey: .agent)
        }
    }
}
