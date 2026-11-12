import Foundation

/// Accumulated tokens and cost over some span (`UsageTotals`).
public struct LeoUsageTotals: Codable, Equatable, Sendable {
    public let tokens: Int64
    public let costUSD: Double

    /// Past this a cost is not a real spend; a payload that says so is malformed.
    public static let maximumCostUSD = 1e7

    public static func isPlausibleCost(_ usd: Double) -> Bool { usd.isFinite && (0...maximumCostUSD).contains(usd) }
}

/// How full the model's context window is (`ContextUsage`).
public struct LeoContextUsage: Codable, Equatable, Sendable {
    public let tokens: Int64
    public let window: Int64
    /// 0...100 as the daemon reports it.
    public let percent: Double
    /// Tokens by source (`context.breakdown`); nil when the daemon sends none.
    public let breakdown: LeoContextBreakdown?
    /// The fraction (0...1) of `window` at which the harness auto-compacts
    /// (`context.compact_at`); nil when absent or out of range.
    public let compactAt: Double?

    /// Anything past this is not a context percentage; a payload that says so is malformed.
    public static let maximumPercent = 1000.0

    public init(tokens: Int64, window: Int64, percent: Double, breakdown: LeoContextBreakdown? = nil, compactAt: Double? = nil) {
        self.tokens = tokens
        self.window = window
        self.percent = percent
        self.breakdown = breakdown
        self.compactAt = compactAt
    }

    enum CodingKeys: String, CodingKey {
        case tokens, window, percent, breakdown
        case compactAt = "compact_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let percent = try container.decode(Double.self, forKey: .percent)
        let tokens = try container.decode(Int64.self, forKey: .tokens)
        let window = try container.decode(Int64.self, forKey: .window)
        guard percent.isFinite, (0...Self.maximumPercent).contains(percent), tokens >= 0, window > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .percent, in: container, debugDescription: "implausible context")
        }
        // The optional parts never fail the context they ride in.
        let breakdown = ((try? container.decodeIfPresent(LeoLenient<LeoContextBreakdown>.self, forKey: .breakdown)) ?? nil)?.value
        let compactAt = ((try? container.decodeIfPresent(Double.self, forKey: .compactAt)) ?? nil)
            .flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        self.init(tokens: tokens, window: window, percent: percent, breakdown: breakdown, compactAt: compactAt)
    }
}

/// Context tokens by source (`context.breakdown`). Every key is optional;
/// unknown keys are dropped and an invalid one reads as absent.
public struct LeoContextBreakdown: Codable, Equatable, Sendable {
    public let system: Int64?
    public let tools: Int64?
    public let mcp: Int64?
    public let memory: Int64?
    public let messages: Int64?

    public init(system: Int64? = nil, tools: Int64? = nil, mcp: Int64? = nil, memory: Int64? = nil, messages: Int64? = nil) {
        self.system = system
        self.tools = tools
        self.mcp = mcp
        self.memory = memory
        self.messages = messages
    }

    enum CodingKeys: String, CodingKey { case system, tools, mcp, memory, messages }

    /// An object with no readable key has nothing to show, so it fails (and a lenient parent reads it as absent).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) -> Int64? {
            ((try? container.decodeIfPresent(Int64.self, forKey: key)) ?? nil).flatMap { $0 >= 0 ? $0 : nil }
        }
        self.init(system: count(.system), tools: count(.tools), mcp: count(.mcp), memory: count(.memory), messages: count(.messages))
        guard [system, tools, mcp, memory, messages].contains(where: { $0 != nil }) else {
            throw DecodingError.dataCorruptedError(forKey: .system, in: container, debugDescription: "empty breakdown")
        }
    }
}

/// A rate-limit window (`rate_limits[]`).
public struct LeoRateLimit: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    public let kind: Kind
    /// 0 up to `maximumPercent`; the harness may briefly report more than 100.
    public let percentUsed: Double
    public let resetsAt: Date

    /// Anything past this is not a usage percentage; an entry that says so is malformed.
    public static let maximumPercent = 1000.0

    public init(kind: Kind, percentUsed: Double, resetsAt: Date) {
        self.kind = kind
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case percentUsed = "percent_used"
        case resetsAt = "resets_at"
    }

    /// Fails on an unknown kind, an implausible percentage or an unreadable
    /// RFC 3339 time, so a lenient list drops just this entry.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let percent = try container.decode(Double.self, forKey: .percentUsed)
        let raw = try container.decode(String.self, forKey: .resetsAt)
        guard percent.isFinite, (0...Self.maximumPercent).contains(percent), let date = LeoRFC3339.date(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .percentUsed, in: container, debugDescription: "implausible rate limit")
        }
        self.init(kind: kind, percentUsed: percent, resetsAt: date)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(percentUsed, forKey: .percentUsed)
        try container.encode(LeoRFC3339.string(resetsAt), forKey: .resetsAt)
    }
}

/// The `rate_limits` list: entries that fail to decode are dropped one by one,
/// and only the first few are looked at.
struct LeoLenientRateLimits: Decodable {
    static let maxEntries = 16
    let elements: [LeoRateLimit]

    private struct Skipped: Decodable {}

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [LeoRateLimit] = []
        var seen = 0
        while !container.isAtEnd, seen < Self.maxEntries {
            seen += 1
            if let limit = try? container.decode(LeoRateLimit.self) {
                elements.append(limit)
            } else {
                _ = try? container.decode(Skipped.self)
            }
        }
        self.elements = elements
    }
}

/// Lines changed in the agent's working tree (`git`).
public struct LeoGitDelta: Codable, Equatable, Sendable {
    public let added: Int64
    public let removed: Int64

    public init(added: Int64, removed: Int64) {
        self.added = added
        self.removed = removed
    }

    enum CodingKeys: String, CodingKey { case added, removed }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let added = try container.decode(Int64.self, forKey: .added)
        let removed = try container.decode(Int64.self, forKey: .removed)
        guard added >= 0, removed >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .added, in: container, debugDescription: "negative line count")
        }
        self.init(added: added, removed: removed)
    }
}

/// RFC 3339 with or without fractional seconds, in UTC on the way out.
enum LeoRFC3339 {
    static func date(_ text: String) -> Date? {
        guard text.utf8.count <= 40 else { return nil }
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    static func string(_ date: Date) -> String { plain.string(from: date) }

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Short display text from the daemon (a model id, an effort level): printable
/// ASCII, 1...64 characters. Anything else reads as absent, so no control
/// characters or oversized strings reach a plugin.
enum LeoUsageText {
    static let maxLength = 64

    static func clean(_ text: String?) -> String? {
        guard let text, (1...maxLength).contains(text.utf8.count),
            text.utf8.allSatisfy({ (0x20...0x7E).contains($0) }),
            !text.allSatisfy({ $0 == " " })
        else { return nil }
        return text
    }
}

/// A value that never fails the object it rides in: malformed reads as nil.
public struct LeoLenient<Value: Decodable & Sendable>: Decodable, Sendable {
    public let value: Value?

    public init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// A bridged agent's usage (leo >= 0.35, `agent_usage`): `session` resets
/// when the Claude session changes, `incarnation` when the agent respawns.
/// Decoding is lenient: a missing or malformed part reads as absent and
/// never fails the payload it rides in.
public struct LeoAgentUsage: Codable, Equatable, Sendable {
    public let sessionID: String?
    public let session: LeoUsageTotals
    public let incarnation: LeoUsageTotals?
    public let context: LeoContextUsage?
    /// The model the harness observed (`usage.model`); nil when not reported.
    public let model: String?
    /// The reasoning effort (`usage.effort`); nil when not reported.
    public let effort: String?
    /// Rate-limit windows (`usage.rate_limits`); at most one per kind, empty when none.
    public let rateLimits: [LeoRateLimit]
    /// Lines changed in the working tree (`usage.git`); nil when not reported.
    public let git: LeoGitDelta?

    public init(
        sessionID: String? = nil, session: LeoUsageTotals, incarnation: LeoUsageTotals? = nil, context: LeoContextUsage? = nil,
        model: String? = nil, effort: String? = nil, rateLimits: [LeoRateLimit] = [], git: LeoGitDelta? = nil
    ) {
        self.sessionID = sessionID
        self.session = session
        self.incarnation = incarnation
        self.context = context
        self.model = model
        self.effort = effort
        self.rateLimits = rateLimits
        self.git = git
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case session, incarnation, context, model, effort, git
        case rateLimits = "rate_limits"
    }

    /// A usage with no readable `session` totals has nothing to show, so it fails.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = (try? container.decodeIfPresent(String.self, forKey: .sessionID)) ?? nil
        session = try container.decode(Totals.self, forKey: .session).value
        incarnation = ((try? container.decodeIfPresent(Totals.self, forKey: .incarnation)) ?? nil)?.value
        context = ((try? container.decodeIfPresent(LeoLenient<LeoContextUsage>.self, forKey: .context)) ?? nil)?.value
        model = LeoUsageText.clean((try? container.decodeIfPresent(String.self, forKey: .model)) ?? nil)
        effort = LeoUsageText.clean((try? container.decodeIfPresent(String.self, forKey: .effort)) ?? nil)
        rateLimits = Self.uniqueByKind(((try? container.decodeIfPresent(LeoLenientRateLimits.self, forKey: .rateLimits)) ?? nil)?.elements ?? [])
        git = ((try? container.decodeIfPresent(LeoLenient<LeoGitDelta>.self, forKey: .git)) ?? nil)?.value
    }

    /// The first entry of each kind wins, so a flood of entries stays bounded.
    private static func uniqueByKind(_ limits: [LeoRateLimit]) -> [LeoRateLimit] {
        var seen = Set<LeoRateLimit.Kind>()
        return limits.filter { seen.insert($0.kind).inserted }
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
public enum LeoTurnOutcome: Equatable, Sendable {
    case completed, aborted, unknown

    public init(wire: String?) {
        switch wire {
        case "completed": self = .completed
        case "aborted": self = .aborted
        default: self = .unknown
        }
    }
}

/// One turn's own token counts.
public struct LeoTurnTokens: Equatable, Sendable {
    public let input: Int64
    public let output: Int64
    public let cacheRead: Int64
    public let cacheCreation: Int64
}

/// `agent_turn_completed`: a bridged agent's turn ended (leo >= 0.35,
/// `bridge_turns`). `preview` is the final message, already sanitized and
/// clamped; display text only.
public struct LeoTurnCompletion: Decodable, Equatable, Sendable {
    public let agent: String
    public let sessionID: String?
    public let outcome: LeoTurnOutcome
    public let preview: String
    public let tokens: LeoTurnTokens?
    public let costUSD: Double?
    public let context: LeoContextUsage?

    public init(
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

    public init(from decoder: any Decoder) throws {
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
