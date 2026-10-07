import Foundation

/// Accumulated tokens and cost over some span (`UsageTotals`).
struct LeoUsageTotals: Codable, Equatable, Sendable {
    let tokens: Int64
    let costUSD: Double

    /// Past this a cost is not a real spend; a payload that says so is malformed.
    static let maximumCostUSD = 1e7

    static func isPlausibleCost(_ usd: Double) -> Bool { usd.isFinite && (0...maximumCostUSD).contains(usd) }
}

/// How full the model's context window is (`ContextUsage`).
struct LeoContextUsage: Codable, Equatable, Sendable {
    let tokens: Int64
    let window: Int64
    /// 0...100 as the daemon reports it.
    let percent: Double

    /// Anything past this is not a context percentage; a payload that says so is malformed.
    static let maximumPercent = 1000.0

    init(tokens: Int64, window: Int64, percent: Double) {
        self.tokens = tokens
        self.window = window
        self.percent = percent
    }

    enum CodingKeys: String, CodingKey { case tokens, window, percent }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let percent = try container.decode(Double.self, forKey: .percent)
        let tokens = try container.decode(Int64.self, forKey: .tokens)
        let window = try container.decode(Int64.self, forKey: .window)
        guard percent.isFinite, (0...Self.maximumPercent).contains(percent), tokens >= 0, window > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .percent, in: container, debugDescription: "implausible context")
        }
        self.init(tokens: tokens, window: window, percent: percent)
    }
}

/// A value that never fails the object it rides in: malformed reads as nil.
struct LeoLenient<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// A bridged agent's usage (leo >= 0.35, `agent_usage`): `session` resets
/// when the Claude session changes, `incarnation` when the agent respawns.
/// Decoding is lenient: a missing or malformed part reads as absent and
/// never fails the payload it rides in.
struct LeoAgentUsage: Codable, Equatable, Sendable {
    let sessionID: String?
    let session: LeoUsageTotals
    let incarnation: LeoUsageTotals?
    let context: LeoContextUsage?

    init(sessionID: String? = nil, session: LeoUsageTotals, incarnation: LeoUsageTotals? = nil, context: LeoContextUsage? = nil) {
        self.sessionID = sessionID
        self.session = session
        self.incarnation = incarnation
        self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case session, incarnation, context
    }

    /// A usage with no readable `session` totals has nothing to show, so it fails.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = (try? container.decodeIfPresent(String.self, forKey: .sessionID)) ?? nil
        session = try container.decode(Totals.self, forKey: .session).value
        incarnation = ((try? container.decodeIfPresent(Totals.self, forKey: .incarnation)) ?? nil)?.value
        context = ((try? container.decodeIfPresent(LeoLenient<LeoContextUsage>.self, forKey: .context)) ?? nil)?.value
    }

    private struct Totals: Decodable {
        let value: LeoUsageTotals

        enum CodingKeys: String, CodingKey { case tokens, costUSD = "cost_usd" }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tokens = try container.decode(Int64.self, forKey: .tokens)
            let cost = (try? container.decodeIfPresent(Double.self, forKey: .costUSD)) ?? nil
            guard tokens >= 0, cost.map(LeoUsageTotals.isPlausibleCost) ?? true else {
                throw DecodingError.dataCorruptedError(forKey: .tokens, in: container, debugDescription: "implausible usage")
            }
            value = LeoUsageTotals(tokens: tokens, costUSD: cost ?? 0)
        }
    }
}

/// How a turn ended. A value this app doesn't know reads as `.unknown`.
enum LeoTurnOutcome: Equatable, Sendable {
    case completed, aborted, unknown

    init(wire: String?) {
        switch wire {
        case "completed": self = .completed
        case "aborted": self = .aborted
        default: self = .unknown
        }
    }
}

/// One turn's own token counts.
struct LeoTurnTokens: Equatable, Sendable {
    let input: Int64
    let output: Int64
    let cacheRead: Int64
    let cacheCreation: Int64
}

/// `agent_turn_completed`: a bridged agent's turn ended (leo >= 0.35,
/// `bridge_turns`). `preview` is the final message, already sanitized and
/// clamped; display text only.
struct LeoTurnCompletion: Decodable, Equatable, Sendable {
    let agent: String
    let sessionID: String?
    let outcome: LeoTurnOutcome
    let preview: String
    let tokens: LeoTurnTokens?
    let costUSD: Double?
    let context: LeoContextUsage?

    init(
        agent: String, sessionID: String? = nil, outcome: LeoTurnOutcome, preview: String, tokens: LeoTurnTokens? = nil,
        costUSD: Double? = nil, context: LeoContextUsage? = nil
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.outcome = outcome
        self.preview = preview
        self.tokens = tokens
        self.costUSD = costUSD
        self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case agent, outcome, preview, tokens, context
        case sessionID = "session_id"
        case costUSD = "cost_usd"
    }

    private struct Tokens: Decodable {
        let input: Int64?
        let output: Int64?
        let cacheRead: Int64?
        let cacheCreation: Int64?

        enum CodingKeys: String, CodingKey {
            case input, output
            case cacheRead = "cache_read"
            case cacheCreation = "cache_creation"
        }

        /// Counts are never negative; one that is makes the whole group untrustworthy.
        var isPlausible: Bool { [input, output, cacheRead, cacheCreation].allSatisfy { ($0 ?? 0) >= 0 } }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(String.self, forKey: .agent)
        sessionID = (try? container.decodeIfPresent(String.self, forKey: .sessionID)) ?? nil
        outcome = LeoTurnOutcome(wire: (try? container.decodeIfPresent(String.self, forKey: .outcome)) ?? nil)
        let rawPreview = (try? container.decodeIfPresent(String.self, forKey: .preview)) ?? nil
        preview = rawPreview.map(LeoSFTPServerText.sanitized) ?? ""
        let rawTokens = (try? container.decodeIfPresent(Tokens.self, forKey: .tokens)) ?? nil
        tokens = rawTokens.flatMap { $0.isPlausible ? $0 : nil }.map {
            LeoTurnTokens(input: $0.input ?? 0, output: $0.output ?? 0, cacheRead: $0.cacheRead ?? 0, cacheCreation: $0.cacheCreation ?? 0)
        }
        costUSD = ((try? container.decodeIfPresent(Double.self, forKey: .costUSD)) ?? nil).flatMap { LeoUsageTotals.isPlausibleCost($0) ? $0 : nil }
        context = ((try? container.decodeIfPresent(LeoLenient<LeoContextUsage>.self, forKey: .context)) ?? nil)?.value
    }
}
