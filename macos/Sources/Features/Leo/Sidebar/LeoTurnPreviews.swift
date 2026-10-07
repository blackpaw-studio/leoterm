import Foundation

/// What a row shows of its agent's last turn (B-259): the final message's
/// preview and how the turn ended. Display text only.
struct LeoTurnPreview: Equatable, Sendable {
    let text: String
    let outcome: LeoTurnOutcome
}

/// The last turn's preview per agent name. The preview exists only on the
/// `agent_turn_completed` event -- `/state` carries none -- so it is kept
/// here, stamped with the `started_at` of the row it arrived for, and
/// attached only to a row of that same incarnation (D-074): a delete +
/// recreate under the same name can never inherit it. Values only; the
/// feed owns the one instance.
struct LeoTurnPreviews: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        let startedAt: String
        let preview: LeoTurnPreview
    }

    private let entries: [String: Entry]
    /// The daemon boot these were recorded under; another boot clears them.
    private let bootID: String?

    static let empty = LeoTurnPreviews(entries: [:], bootID: nil)

    /// Records `completion` for the incarnation `startedAt`. An empty
    /// preview clears the line instead: never invent text.
    func recording(_ completion: LeoTurnCompletion, startedAt: String) -> LeoTurnPreviews {
        var next = entries
        next[completion.agent] = completion.preview.isEmpty
            ? nil
            : Entry(startedAt: startedAt, preview: LeoTurnPreview(text: completion.preview, outcome: completion.outcome))
        return LeoTurnPreviews(entries: next, bootID: bootID)
    }

    func forgetting(_ name: String) -> LeoTurnPreviews {
        guard entries[name] != nil else { return self }
        return LeoTurnPreviews(entries: entries.filter { $0.key != name }, bootID: bootID)
    }

    /// Everything recorded under another daemon boot is dropped; the first
    /// boot seen (or none advertised) keeps what's there. Only fires on a
    /// second hello on the same stream: a disconnect already resets the store.
    func observingBoot(_ boot: String?) -> LeoTurnPreviews {
        guard let boot else { return self }
        return LeoTurnPreviews(entries: boot == bootID || bootID == nil ? entries : [:], bootID: boot)
    }

    func preview(name: String, startedAt: String?) -> LeoTurnPreview? {
        guard let startedAt, let entry = entries[name], entry.startedAt == startedAt else { return nil }
        return entry.preview
    }

    func attach(to rows: [LeoAgentRow]) -> [LeoAgentRow] {
        rows.map { $0.withLastTurn(preview(name: $0.name, startedAt: $0.startedAt)) }
    }
}
