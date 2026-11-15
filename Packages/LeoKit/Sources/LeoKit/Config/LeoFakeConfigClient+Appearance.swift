import Foundation

/// What a fake daemon knows about appearance: the rules (validated as the
/// daemon does), the agents they resolve against, and each agent's manual
/// values. Only a seeded agent has a record; any other name is a 404.
public struct LeoFakeAppearanceState: Sendable {
    var rules: [LeoAppearanceRule] = []
    var agents: [String: LeoAppearanceFacts] = [:]
    var manual: [String: LeoAppearanceManual] = [:]

    func resolved(_ name: String) -> LeoAgentAppearance? {
        agents[name].flatMap { LeoAppearanceResolver.resolve(rules: rules, facts: $0, manual: manual[name]) }
    }
}

extension LeoFakeConfigClient: LeoAppearanceAPI {
    /// Seeds the agents rules resolve against, with optional manual values.
    public func seedAppearance(agents: [LeoAppearanceFacts], rules: [LeoAppearanceRule] = [], manual: [String: LeoAppearanceManual] = [:]) {
        appearanceState.agents = Dictionary(agents.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        appearanceState.rules = rules
        appearanceState.manual = manual
    }

    public func appearanceRules() async throws -> LeoAppearanceRulesDocument {
        calls.append(.appearanceRules)
        try await beforeRead()
        return appearanceDocument()
    }

    public func setAppearanceRules(_ rules: [LeoAppearanceRule], ifMatch: String) async throws -> LeoAppearanceRulesDocument {
        calls.append(.setAppearanceRules(rules, ifMatch: ifMatch))
        if isHoldingWrites { await withCheckedContinuation { heldWrites.append($0) } }
        try beforeWrite(ifMatch)
        if let (index, rule) = rules.enumerated().first(where: { !$0.element.isValid }) {
            throw LeoAppearanceError.invalidRule(index: index, reason: rule.problem ?? "")
        }
        appearanceState.rules = rules
        revisionNumber += 1
        return appearanceDocument()
    }

    public func setAgentAppearance(
        name: String, emoji: LeoAppearanceChange<String>, color: LeoAppearanceChange<LeoAppearanceColor>
    ) async throws -> LeoAgentAppearanceResult {
        calls.append(.setAgentAppearance(name: name, emoji: emoji, color: color))
        if isHoldingWrites { await withCheckedContinuation { heldWrites.append($0) } }
        if let failure = takeWriteFailure() { throw failure }
        guard appearanceState.agents[name] != nil else {
            throw LeoDaemonError.daemon(code: "not_found", message: "agent \"\(name)\" not found", matches: [])
        }
        if case .set(let text) = emoji, !LeoEmoji.isSingleGrapheme(text) {
            let probe = LeoAppearanceRule(field: "name", op: "is", value: name, emoji: text)
            throw LeoAppearanceError.invalidValue(field: LeoAppearanceWire.emojiKey, reason: probe.problem ?? "")
        }
        let current = appearanceState.manual[name]
        appearanceState.manual[name] = LeoAppearanceManual(emoji: emoji.applied(to: current?.emoji), color: color.applied(to: current?.color))
        return LeoAgentAppearanceResult(agent: name, appearance: appearanceState.resolved(name))
    }

    private func appearanceDocument() -> LeoAppearanceRulesDocument {
        let errors = appearanceState.rules.enumerated().compactMap { index, rule in
            rule.problem.map { LeoAppearanceRuleProblem(index: index, reason: $0) }
        }
        return LeoAppearanceRulesDocument(revision: revision, rules: appearanceState.rules, errors: errors)
    }
}
