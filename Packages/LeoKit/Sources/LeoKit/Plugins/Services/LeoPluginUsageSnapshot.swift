import Foundation

/// What the app knows about one agent's usage when a plugin asks.
public struct LeoPluginUsageReading: Equatable, Sendable {
    /// The agent's configured model; the fallback when the harness reported no observed one.
    public let configuredModel: String?
    /// The latest usage, nil until the agent has reported any.
    public let usage: LeoAgentUsage?
    /// False when the agent's harness is known never to report usage, so a
    /// plugin gets `{}` ("don't wait") instead of `null` ("not yet").
    public let harnessReportsUsage: Bool

    public init(configuredModel: String?, usage: LeoAgentUsage?, harnessReportsUsage: Bool) {
        self.configuredModel = configuredModel
        self.usage = usage
        self.harnessReportsUsage = harnessReportsUsage
    }
}

/// `leo.agents.usage(agent)`: the usage a plugin may see, as camelCase JSON.
/// Requires `agents:usage`. Only fields in the published contract are built
/// here, so nothing else the daemon sends can cross into a plugin, and an
/// absent field is left out rather than sent as `null` or zero.
public enum LeoPluginUsageSnapshot {
    /// - `null`: no reading, or the agent has not reported anything usable yet.
    /// - `{}`: the harness does not report usage.
    public static func value(reading: LeoPluginUsageReading?, engine: LeoPluginPermissionEngine) throws -> LeoJSONValue {
        if case .denied(let reason) = engine.check(agent: .usage) { throw LeoPluginAgentsSnapshotError.permissionDenied(reason) }
        guard let reading else { return .null }
        guard reading.harnessReportsUsage else { return .object([:]) }
        guard let usage = reading.usage else { return .null }
        let fields = fields(for: usage, configuredModel: reading.configuredModel)
        return fields.isEmpty ? .null : .object(fields)
    }

    /// The observed model when the harness reported one, else the configured one.
    public static func model(observed: String?, configured: String?) -> String? {
        LeoUsageText.clean(observed) ?? LeoUsageText.clean(configured)
    }

    private static func fields(for usage: LeoAgentUsage, configuredModel: String?) -> [String: LeoJSONValue] {
        var fields: [String: LeoJSONValue] = [:]
        fields["model"] = model(observed: usage.model, configured: configuredModel).map(LeoJSONValue.string)
        fields["effort"] = LeoUsageText.clean(usage.effort).map(LeoJSONValue.string)
        fields["context"] = usage.context.flatMap(context)
        fields["session"] = session(usage)
        let limits = usage.rateLimits.compactMap(rateLimit)
        fields["rateLimits"] = limits.isEmpty ? nil : .array(limits)
        fields["git"] = usage.git.flatMap(git)
        return fields
    }

    /// The contract's `session` has both a token count and a cost, so a missing or implausible cost drops the whole object.
    private static func session(_ usage: LeoAgentUsage) -> LeoJSONValue? {
        let totals = usage.session
        guard usage.isSessionCostReported, totals.tokens >= 0, LeoUsageTotals.isPlausibleCost(totals.costUSD) else { return nil }
        return .object(["tokens": .int(Int(totals.tokens)), "costUsd": .double(totals.costUSD)])
    }

    private static func context(_ context: LeoContextUsage) -> LeoJSONValue? {
        guard context.tokens >= 0, context.window > 0, context.percent.isFinite,
            (0...LeoContextUsage.maximumPercent).contains(context.percent)
        else { return nil }
        var fields: [String: LeoJSONValue] = [
            "tokens": .int(Int(context.tokens)), "window": .int(Int(context.window)), "percent": .double(context.percent),
        ]
        if let compactAt = context.compactAt, compactAt.isFinite, (0...1).contains(compactAt) { fields["compactAt"] = .double(compactAt) }
        if let breakdown = context.breakdown { fields["breakdown"] = self.breakdown(breakdown) }
        return .object(fields)
    }

    private static func breakdown(_ breakdown: LeoContextBreakdown) -> LeoJSONValue? {
        let parts: [(String, Int64?)] = [
            ("system", breakdown.system), ("tools", breakdown.tools), ("mcp", breakdown.mcp),
            ("memory", breakdown.memory), ("messages", breakdown.messages),
        ]
        let fields = parts.reduce(into: [String: LeoJSONValue]()) { result, part in
            if let value = part.1, value >= 0 { result[part.0] = .int(Int(value)) }
        }
        return fields.isEmpty ? nil : .object(fields)
    }

    private static func rateLimit(_ limit: LeoRateLimit) -> LeoJSONValue? {
        guard limit.percentUsed.isFinite, (0...LeoRateLimit.maximumPercent).contains(limit.percentUsed) else { return nil }
        var fields: [String: LeoJSONValue] = ["kind": .string(limit.kind.rawValue), "percentUsed": .double(limit.percentUsed)]
        if let resetsAt = limit.resetsAt { fields["resetsAt"] = .string(LeoRFC3339.string(resetsAt)) }
        return .object(fields)
    }

    private static func git(_ git: LeoGitDelta) -> LeoJSONValue? {
        guard git.added >= 0, git.removed >= 0 else { return nil }
        return .object(["added": .int(Int(git.added)), "removed": .int(Int(git.removed))])
    }
}
