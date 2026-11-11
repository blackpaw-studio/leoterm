import Foundation

// Bridge protocol between a plugin's JS host and the app.
//
// Security shape: the host can ask for exactly the cases below. There is no
// request for sending to or spawning an agent. Anything unrecognised decodes
// to `.unsupported` and the router rejects it. The only path from plugin code
// to a send or spawn is `.callbackResult(ref:action:)`, which the app honours
// through `LeoPluginActionGate.authorizeFollowUp` (gesture + permission +
// confirmation sheet).

public struct LeoPluginFetchInit: Codable, Equatable, Sendable {
    public let method: String?
    public let headers: [String: String]?
    public let body: String?

    public init(method: String? = nil, headers: [String: String]? = nil, body: String? = nil) {
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// Host → app. Wire form: `{"call": "<case>", ...fields}`.
public enum LeoPluginHostRequest: Codable, Equatable, Sendable {
    case render(slot: LeoPluginSlotID, node: LeoPluginSlotRoot)
    case fetch(id: String, url: String, init: LeoPluginFetchInit)
    case secretsGet(id: String, key: String)
    case secretsSet(id: String, key: String, value: String)
    case secretsDelete(id: String, key: String)
    case agentsList(id: String)
    /// Periodic; the router enforces `seconds >= 60`.
    case timerStart(id: String, seconds: Double)
    /// One-shot (`leo.after`); the router enforces `seconds >= 1`.
    case afterStart(id: String, seconds: Double)
    /// Cancels a `timerStart` or `afterStart`.
    case timerStop(id: String)
    case log(level: String, message: String)
    /// A callback handler's single follow-up action. Gated by the app.
    case callbackResult(ref: String, action: LeoPluginAction)
    case handlerError(source: String, message: String)
    case unsupported(call: String)

    private enum CodingKeys: String, CodingKey {
        case call, slot, node, id, url, `init`, key, value, seconds, level, message, ref, action, source
    }

    public init(from decoder: any Decoder) throws {
        let scope = try LeoPluginDecodeBudget.enter(decoder)
        defer { scope.exit() }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let call = try c.decodeIfPresent(String.self, forKey: .call) ?? ""
        switch call {
        case "render":
            self = .render(
                slot: try c.decode(LeoPluginSlotID.self, forKey: .slot),
                node: try c.decode(LeoPluginSlotRoot.self, forKey: .node))
        case "fetch":
            self = .fetch(
                id: try c.decode(String.self, forKey: .id),
                url: try c.decode(String.self, forKey: .url),
                init: try c.decodeIfPresent(LeoPluginFetchInit.self, forKey: .`init`) ?? LeoPluginFetchInit())
        case "secretsGet":
            self = .secretsGet(id: try c.decode(String.self, forKey: .id), key: try c.decode(String.self, forKey: .key))
        case "secretsSet":
            self = .secretsSet(
                id: try c.decode(String.self, forKey: .id),
                key: try c.decode(String.self, forKey: .key),
                value: try c.decode(String.self, forKey: .value))
        case "secretsDelete":
            self = .secretsDelete(id: try c.decode(String.self, forKey: .id), key: try c.decode(String.self, forKey: .key))
        case "agentsList":
            self = .agentsList(id: try c.decode(String.self, forKey: .id))
        case "timerStart":
            self = .timerStart(id: try c.decode(String.self, forKey: .id), seconds: try c.decode(Double.self, forKey: .seconds))
        case "afterStart":
            self = .afterStart(id: try c.decode(String.self, forKey: .id), seconds: try c.decode(Double.self, forKey: .seconds))
        case "timerStop":
            self = .timerStop(id: try c.decode(String.self, forKey: .id))
        case "log":
            self = .log(level: try c.decode(String.self, forKey: .level), message: try c.decode(String.self, forKey: .message))
        case "callbackResult":
            self = .callbackResult(
                ref: try c.decode(String.self, forKey: .ref),
                action: try c.decode(LeoPluginAction.self, forKey: .action))
        case "handlerError":
            self = .handlerError(
                source: try c.decodeIfPresent(String.self, forKey: .source) ?? "",
                message: try c.decode(String.self, forKey: .message))
        default:
            self = .unsupported(call: call)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .render(let slot, let node):
            try c.encode("render", forKey: .call)
            try c.encode(slot, forKey: .slot)
            try c.encode(node, forKey: .node)
        case .fetch(let id, let url, let fetchInit):
            try c.encode("fetch", forKey: .call)
            try c.encode(id, forKey: .id)
            try c.encode(url, forKey: .url)
            try c.encode(fetchInit, forKey: .`init`)
        case .secretsGet(let id, let key):
            try c.encode("secretsGet", forKey: .call)
            try c.encode(id, forKey: .id)
            try c.encode(key, forKey: .key)
        case .secretsSet(let id, let key, let value):
            try c.encode("secretsSet", forKey: .call)
            try c.encode(id, forKey: .id)
            try c.encode(key, forKey: .key)
            try c.encode(value, forKey: .value)
        case .secretsDelete(let id, let key):
            try c.encode("secretsDelete", forKey: .call)
            try c.encode(id, forKey: .id)
            try c.encode(key, forKey: .key)
        case .agentsList(let id):
            try c.encode("agentsList", forKey: .call)
            try c.encode(id, forKey: .id)
        case .timerStart(let id, let seconds):
            try c.encode("timerStart", forKey: .call)
            try c.encode(id, forKey: .id)
            try c.encode(seconds, forKey: .seconds)
        case .afterStart(let id, let seconds):
            try c.encode("afterStart", forKey: .call)
            try c.encode(id, forKey: .id)
            try c.encode(seconds, forKey: .seconds)
        case .timerStop(let id):
            try c.encode("timerStop", forKey: .call)
            try c.encode(id, forKey: .id)
        case .log(let level, let message):
            try c.encode("log", forKey: .call)
            try c.encode(level, forKey: .level)
            try c.encode(message, forKey: .message)
        case .callbackResult(let ref, let action):
            try c.encode("callbackResult", forKey: .call)
            try c.encode(ref, forKey: .ref)
            try c.encode(action, forKey: .action)
        case .handlerError(let source, let message):
            try c.encode("handlerError", forKey: .call)
            try c.encode(source, forKey: .source)
            try c.encode(message, forKey: .message)
        case .unsupported(let call):
            try c.encode(call, forKey: .call)
        }
    }
}

/// How the app answers a request that has an `id`.
public enum LeoPluginReplyOutcome: Codable, Equatable, Sendable {
    case value(LeoJSONValue)
    case rejected(reason: String)

    private enum CodingKeys: String, CodingKey { case outcome, value, reason }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .outcome) {
        case "value": self = .value(try c.decodeIfPresent(LeoJSONValue.self, forKey: .value) ?? .null)
        case "rejected": self = .rejected(reason: try c.decode(String.self, forKey: .reason))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .outcome, in: c, debugDescription: "unknown outcome \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .value(let value):
            try c.encode("value", forKey: .outcome)
            try c.encode(value, forKey: .value)
        case .rejected(let reason):
            try c.encode("rejected", forKey: .outcome)
            try c.encode(reason, forKey: .reason)
        }
    }
}

/// App → host. Wire form: `{"type": "<case>", ...fields}`.
public enum LeoPluginEvent: Codable, Equatable, Sendable {
    case activate(slot: LeoPluginSlotID?)
    case agentsChanged
    case viewOpened(agent: LeoPluginAgentRef, slot: LeoPluginSlotID)
    case command(id: String, slot: LeoPluginSlotID?)
    /// `ref` correlates a follow-up (`callbackResult`) with this delivery.
    /// `gesture` says the app minted a gesture for it; the host never sees
    /// the token itself.
    case callback(ref: String, id: String, payload: LeoJSONValue, gesture: Bool)
    case timerFired(id: String)
    case reply(id: String, outcome: LeoPluginReplyOutcome)

    private enum CodingKeys: String, CodingKey {
        case type, slot, agent, id, ref, payload, gesture, outcome, value, reason
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "activate":
            self = .activate(slot: try c.decodeIfPresent(LeoPluginSlotID.self, forKey: .slot))
        case "agentsChanged":
            self = .agentsChanged
        case "viewOpened":
            self = .viewOpened(
                agent: try c.decode(LeoPluginAgentRef.self, forKey: .agent),
                slot: try c.decode(LeoPluginSlotID.self, forKey: .slot))
        case "command":
            self = .command(
                id: try c.decode(String.self, forKey: .id),
                slot: try c.decodeIfPresent(LeoPluginSlotID.self, forKey: .slot))
        case "callback":
            self = .callback(
                ref: try c.decode(String.self, forKey: .ref),
                id: try c.decode(String.self, forKey: .id),
                payload: try c.decodeIfPresent(LeoJSONValue.self, forKey: .payload) ?? .null,
                gesture: try c.decodeIfPresent(Bool.self, forKey: .gesture) ?? false)
        case "timerFired":
            self = .timerFired(id: try c.decode(String.self, forKey: .id))
        case "reply":
            self = .reply(id: try c.decode(String.self, forKey: .id), outcome: try LeoPluginReplyOutcome(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown event type \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .activate(let slot):
            try c.encode("activate", forKey: .type)
            try c.encodeIfPresent(slot, forKey: .slot)
        case .agentsChanged:
            try c.encode("agentsChanged", forKey: .type)
        case .viewOpened(let agent, let slot):
            try c.encode("viewOpened", forKey: .type)
            try c.encode(agent, forKey: .agent)
            try c.encode(slot, forKey: .slot)
        case .command(let id, let slot):
            try c.encode("command", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(slot, forKey: .slot)
        case .callback(let ref, let id, let payload, let gesture):
            try c.encode("callback", forKey: .type)
            try c.encode(ref, forKey: .ref)
            try c.encode(id, forKey: .id)
            try c.encode(payload, forKey: .payload)
            try c.encode(gesture, forKey: .gesture)
        case .timerFired(let id):
            try c.encode("timerFired", forKey: .type)
            try c.encode(id, forKey: .id)
        case .reply(let id, let outcome):
            try c.encode("reply", forKey: .type)
            try c.encode(id, forKey: .id)
            try outcome.encode(to: encoder)
        }
    }
}
