import Foundation

extension LeoConfigHTTPClient: LeoAppearanceAPI {
    public func appearanceRules() async throws -> LeoAppearanceRulesDocument {
        try await read("\(prefix)\(LeoAppearanceWire.rulesRoute)")
    }

    public func setAppearanceRules(_ rules: [LeoAppearanceRule], ifMatch: String) async throws -> LeoAppearanceRulesDocument {
        try await exchange("PUT", "\(prefix)\(LeoAppearanceWire.rulesRoute)", body: ["rules": .list(rules.map(Self.value))], ifMatch: ifMatch)
    }

    public func setAgentAppearance(
        name: String, emoji: LeoAppearanceChange<String>, color: LeoAppearanceChange<LeoAppearanceColor>
    ) async throws -> LeoAgentAppearanceResult {
        let body = [
            LeoAppearanceWire.emojiKey: Self.value(emoji, \.self),
            LeoAppearanceWire.colorKey: Self.value(color, \.rawValue),
        ].compactMapValues { $0 }
        let path = "\(prefix)/agents/\(try Self.segment(name, what: "Agent name"))/\(LeoAppearanceWire.agentAction)"
        return try await exchange("PUT", path, body: body)
    }

    /// Absent when unchanged, `null` when cleared.
    private static func value<Value>(_ change: LeoAppearanceChange<Value>, _ wire: (Value) -> String) -> LeoConfigValue? {
        switch change {
        case .unchanged: nil
        case .cleared: .null
        case .set(let value): .string(wire(value))
        }
    }

    private static func value(_ rule: LeoAppearanceRule) -> LeoConfigValue {
        let when: [String: LeoConfigValue] = ["field": .string(rule.when.field), "op": .string(rule.when.op), "value": .string(rule.when.value)]
        let sets: [String: LeoConfigValue?] = [
            LeoAppearanceWire.colorKey: rule.color.map(LeoConfigValue.string),
            LeoAppearanceWire.emojiKey: rule.emoji.map(LeoConfigValue.string),
        ]
        return .object(sets.compactMapValues { $0 }.merging(["when": .object(when)]) { _, when in when })
    }
}
