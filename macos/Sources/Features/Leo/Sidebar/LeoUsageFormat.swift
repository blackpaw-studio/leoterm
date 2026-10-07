import Foundation

/// How a row writes an agent's usage (B-259): a compact line for the
/// subtitle, and the whole numbers for the tooltip and VoiceOver.
enum LeoUsageFormat {
    /// "999", "12.3k", "1.2M": one decimal, a trailing ".0" dropped.
    static func tokens(_ count: Int64) -> String {
        switch count {
        case ..<1000: return String(max(count, 0))
        case ..<999_950: return scaled(Double(count) / 1000, suffix: "k")
        default: return scaled(Double(count) / 1_000_000, suffix: "M")
        }
    }

    /// "$0.42"; "<$0.01" for any spend below a cent; "$0.00" for none.
    static func cost(_ usd: Double) -> String {
        guard usd > 0 else { return "$0.00" }
        return usd < 0.005 ? "<$0.01" : String(format: "$%.2f", usd)
    }

    /// "37% ctx", rounded to a whole percent.
    static func context(_ context: LeoContextUsage) -> String {
        "\(wholePercent(context))% ctx"
    }

    /// "12.3k tok · $0.42 · 37% ctx" -- the session's, the part worth a glance.
    static func summary(_ usage: LeoAgentUsage) -> String {
        ["\(tokens(usage.session.tokens)) tok", cost(usage.session.costUSD), usage.context.map(context)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Nothing worth a line: no tokens, no spend, no context.
    static func isEmpty(_ usage: LeoAgentUsage) -> Bool {
        usage.session.tokens == 0 && usage.session.costUSD == 0 && usage.context == nil
    }

    /// The whole numbers, one fact per line, for the hover.
    static func tooltip(_ usage: LeoAgentUsage) -> String {
        var lines = ["Session: \(grouped(usage.session.tokens)) tokens, \(cost(usage.session.costUSD))"]
        if let incarnation = usage.incarnation {
            lines.append("Since start: \(grouped(incarnation.tokens)) tokens, \(cost(incarnation.costUSD))")
        }
        if let context = usage.context {
            lines.append("Context: \(grouped(context.tokens)) of \(grouped(context.window)) tokens (\(wholePercent(context))%)")
        }
        return lines.joined(separator: "\n")
    }

    /// How VoiceOver says the summary.
    static func spoken(_ usage: LeoAgentUsage) -> String {
        var parts = ["used \(grouped(usage.session.tokens)) tokens", "\(cost(usage.session.costUSD).replacingOccurrences(of: "<", with: "under "))"]
        if let context = usage.context { parts.append("context \(wholePercent(context)) percent full") }
        return parts.joined(separator: ", ")
    }

    /// Whole percent, clamped so no value can overflow the conversion.
    private static func wholePercent(_ context: LeoContextUsage) -> Int {
        Int(min(max(context.percent, 0), LeoContextUsage.maximumPercent).rounded())
    }

    private static func scaled(_ value: Double, suffix: String) -> String {
        let text = String(format: "%.1f", value)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
    }

    private static func grouped(_ count: Int64) -> String {
        count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}
