import Foundation

/// One field of a manual appearance write: absent leaves it, `null` clears
/// it, a value sets it.
public enum LeoAppearanceChange<Value: Equatable & Sendable>: Equatable, Sendable {
    case unchanged
    case cleared
    case set(Value)

    public func applied(to current: Value?) -> Value? {
        switch self {
        case .unchanged: current
        case .cleared: nil
        case .set(let value): value
        }
    }
}

/// `PUT /agents/{name}/appearance`'s answer: the agent's resolved
/// appearance after the write (nil when nothing is set).
public struct LeoAgentAppearanceResult: Decodable, Equatable, Sendable {
    public let agent: String
    public let appearance: LeoAgentAppearance?

    public init(agent: String, appearance: LeoAgentAppearance?) {
        self.agent = agent
        self.appearance = appearance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LeoEnvironmentsWire.Key.self)
        self.init(
            agent: try container.decode(String.self, forKey: .init(stringValue: "agent")),
            appearance: LeoAppearanceWire.agent(from: decoder)
        )
    }
}

/// The appearance routes' own 400s. A stale revision is
/// `LeoConfigError.conflict` and a missing one `.revisionRequired`, as on
/// the rest of the config API; anything else is a `LeoDaemonError`.
public enum LeoAppearanceError: Error, Equatable, Sendable {
    /// `invalid_appearance_rule`: the first bad rule of a rules write.
    case invalidRule(index: Int, reason: String)
    /// `invalid_appearance`: a manual value off the palette or not one emoji.
    case invalidValue(field: String, reason: String)
}

extension LeoAppearanceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRule(let index, let reason): "Rule \(index + 1): \(reason)"
        case .invalidValue(_, let reason): reason
        }
    }
}

/// Agent appearance on a daemon advertising `agent_appearance` (leo PR
/// #306), over the socket (bare routes) or `/api/v1`.
public protocol LeoAppearanceAPI: Sendable {
    /// `GET /appearance/rules`.
    func appearanceRules() async throws -> LeoAppearanceRulesDocument
    /// `PUT /appearance/rules`: replaces the whole list; `ifMatch` is required.
    func setAppearanceRules(_ rules: [LeoAppearanceRule], ifMatch: String) async throws -> LeoAppearanceRulesDocument
    /// `PUT /agents/{name}/appearance`. "Reset to rules" clears both.
    func setAgentAppearance(
        name: String, emoji: LeoAppearanceChange<String>, color: LeoAppearanceChange<LeoAppearanceColor>
    ) async throws -> LeoAgentAppearanceResult
}
