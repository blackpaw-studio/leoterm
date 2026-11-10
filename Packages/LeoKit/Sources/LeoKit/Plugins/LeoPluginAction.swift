import Foundation

/// A top-level agent a plugin action targets (Q16: dispatches are out).
public struct LeoPluginAgentRef: Codable, Hashable, Sendable {
    public let machine: String
    public let name: String

    public init(machine: String, name: String) {
        self.machine = machine
        self.name = name
    }
}

/// Fields of a `spawnAgent` action. The confirmation sheet makes every one
/// of them editable before anything reaches the daemon.
public struct LeoPluginSpawnSpec: Codable, Equatable, Sendable {
    public let repo: String
    public let branch: String
    public let base: String?
    public let prompt: String
    public let machine: String?

    public init(repo: String, branch: String, base: String?, prompt: String, machine: String?) {
        self.repo = repo
        self.branch = branch
        self.base = base
        self.prompt = prompt
        self.machine = machine
    }
}

/// What a plugin can ask Leo to do from a list item, a form submit or a
/// callback's follow-up. Actions are plain data: plugin code never *calls*
/// `sendToAgent` or `spawnAgent`, it can only return them, and the app
/// decides (see `LeoPluginActionGate`).
///
/// Wire form: `{"type": "<case>", ...fields}`.
public enum LeoPluginAction: Codable, Equatable, Sendable {
    case callback(id: String, payload: LeoJSONValue)
    /// The node is the raw component tree until the typed `LeoPluginNode`
    /// (step 1.4) lands; reconcile by swapping the payload type.
    case pushView(node: LeoJSONValue)
    case openURL(String)
    case copy(String)
    case sendToAgent(agent: LeoPluginAgentRef, text: String)
    case spawnAgent(LeoPluginSpawnSpec)

    private enum CodingKeys: String, CodingKey {
        case type, id, payload, node, url, text, agent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "callback":
            self = .callback(
                id: try container.decode(String.self, forKey: .id),
                payload: try container.decodeIfPresent(LeoJSONValue.self, forKey: .payload) ?? .null)
        case "pushView":
            self = .pushView(node: try container.decode(LeoJSONValue.self, forKey: .node))
        case "openURL":
            self = .openURL(try container.decode(String.self, forKey: .url))
        case "copy":
            self = .copy(try container.decode(String.self, forKey: .text))
        case "sendToAgent":
            self = .sendToAgent(
                agent: try container.decode(LeoPluginAgentRef.self, forKey: .agent),
                text: try container.decode(String.self, forKey: .text))
        case "spawnAgent":
            self = .spawnAgent(try LeoPluginSpawnSpec(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown action type \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .callback(let id, let payload):
            try container.encode("callback", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(payload, forKey: .payload)
        case .pushView(let node):
            try container.encode("pushView", forKey: .type)
            try container.encode(node, forKey: .node)
        case .openURL(let url):
            try container.encode("openURL", forKey: .type)
            try container.encode(url, forKey: .url)
        case .copy(let text):
            try container.encode("copy", forKey: .type)
            try container.encode(text, forKey: .text)
        case .sendToAgent(let agent, let text):
            try container.encode("sendToAgent", forKey: .type)
            try container.encode(agent, forKey: .agent)
            try container.encode(text, forKey: .text)
        case .spawnAgent(let spec):
            try container.encode("spawnAgent", forKey: .type)
            try spec.encode(to: encoder)
        }
    }
}
