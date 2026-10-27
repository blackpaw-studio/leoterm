import Foundation

/// The fixed palette an agent's color comes from (leo `agent_appearance`),
/// in the daemon's display order. Each app maps a name to its own light and
/// dark shade; there are no hex colors.
public enum LeoAppearanceColor: String, CaseIterable, Equatable, Sendable {
    case red, orange, yellow, green, teal, blue, indigo, purple, pink, gray

    /// "Teal", for menus and source lines.
    public var displayName: String { rawValue.capitalized }
}

/// An agent's resolved emoji and color, each with where it came from. The
/// daemon resolves it; the app only shows it. Nil on an agent means nothing
/// is set (the daemon omits the key), which looks exactly like today's row.
public struct LeoAgentAppearance: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Set by hand on this agent.
        case manual
        /// From `appearance_rules[i]` (0-based).
        case rule(Int)

        /// `manual` or `rule:<i>`; nil for anything else.
        public init?(wire: String) {
            if wire == LeoAppearanceWire.manualSource {
                self = .manual
                return
            }
            guard wire.hasPrefix(LeoAppearanceWire.rulePrefix),
                  let index = Int(wire.dropFirst(LeoAppearanceWire.rulePrefix.count)), index >= 0 else { return nil }
            self = .rule(index)
        }

        public var wireValue: String {
            switch self {
            case .manual: LeoAppearanceWire.manualSource
            case .rule(let index): "\(LeoAppearanceWire.rulePrefix)\(index)"
            }
        }
    }

    public let emoji: String?
    public let color: LeoAppearanceColor?
    public let emojiSource: Source?
    public let colorSource: Source?

    public init(emoji: String?, color: LeoAppearanceColor?, emojiSource: Source? = nil, colorSource: Source? = nil) {
        self.emoji = emoji
        self.color = color
        self.emojiSource = emojiSource
        self.colorSource = colorSource
    }

    public var isEmpty: Bool { emoji == nil && color == nil }
}

/// The only place that knows the agent-appearance wire format (leo PR
/// #306): key names, routes and the source strings. Decoding is lenient
/// throughout: a malformed or unknown value reads as unset, never an error,
/// so `/state` and the event stream never fail on it.
public enum LeoAppearanceWire {
    public static let key = "appearance"
    public static let emojiKey = "emoji"
    public static let colorKey = "color"
    public static let emojiSourceKey = "emoji_source"
    public static let colorSourceKey = "color_source"
    public static let manualSource = "manual"
    public static let rulePrefix = "rule:"
    public static let eventType = "agent_appearance_changed"
    /// `GET`/`PUT`, unprefixed on the socket and under `/api/v1` on the web.
    public static let rulesRoute = "/appearance/rules"
    /// `PUT /agents/{name}/appearance`.
    public static let agentAction = "appearance"

    /// An agent object's `appearance`. Nil when absent, malformed, or when
    /// nothing this app knows is set.
    public static func agent(from decoder: any Decoder) -> LeoAgentAppearance? {
        guard let container = try? decoder.container(keyedBy: LeoEnvironmentsWire.Key.self),
              let nested = try? container.nestedContainer(keyedBy: LeoEnvironmentsWire.Key.self, forKey: .init(stringValue: key))
        else { return nil }
        return appearance(in: nested)
    }

    /// An `agent_appearance_changed` payload. Nil when it is malformed (no
    /// agent, or an appearance that is neither an object nor null), so the
    /// caller keeps only its sequence and never clears on a bad event.
    static func event(_ data: Data) -> (seq: Int, at: String?, agent: String, appearance: LeoAgentAppearance?)? {
        struct Payload: Decodable {
            let seq: Int
            let at: String?
            let agent: String
            let appearance: LeoAgentAppearance?

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: LeoEnvironmentsWire.Key.self)
                seq = try container.decode(Int.self, forKey: .init(stringValue: "seq"))
                at = try? container.decodeIfPresent(String.self, forKey: .init(stringValue: "at"))
                agent = try container.decode(String.self, forKey: .init(stringValue: "agent"))
                let appearanceKey = LeoEnvironmentsWire.Key(stringValue: LeoAppearanceWire.key)
                if try container.decodeNil(forKey: appearanceKey) {
                    appearance = nil
                } else {
                    appearance = LeoAppearanceWire.appearance(
                        in: try container.nestedContainer(keyedBy: LeoEnvironmentsWire.Key.self, forKey: appearanceKey)
                    )
                }
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return (payload.seq, payload.at, payload.agent, payload.appearance)
    }

    private static func appearance(in container: KeyedDecodingContainer<LeoEnvironmentsWire.Key>) -> LeoAgentAppearance? {
        func string(_ name: String) -> String? {
            (try? container.decodeIfPresent(String.self, forKey: .init(stringValue: name))) ?? nil
        }
        let emoji = string(emojiKey).flatMap { $0.isEmpty ? nil : $0 }
        let color = string(colorKey).flatMap(LeoAppearanceColor.init(rawValue:))
        let appearance = LeoAgentAppearance(
            emoji: emoji, color: color,
            emojiSource: emoji == nil ? nil : string(emojiSourceKey).flatMap(LeoAgentAppearance.Source.init(wire:)),
            colorSource: color == nil ? nil : string(colorSourceKey).flatMap(LeoAgentAppearance.Source.init(wire:))
        )
        return appearance.isEmpty ? nil : appearance
    }
}
