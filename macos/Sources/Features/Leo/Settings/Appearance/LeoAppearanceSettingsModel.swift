import Foundation
import LeoKit

/// One agent the Appearance pane previews: the facts rules test and its
/// hand-set values, taken from the sidebar's rows for the machine.
struct LeoAppearancePreviewAgent: Equatable, Sendable {
    let name: String
    let environments: [String]
    let template: String
    let manual: LeoAppearanceManual?

    /// The manual values are the ones whose source says so.
    init(row: LeoAgentRow) {
        let appearance = row.appearance
        let emoji = appearance?.emojiSource == .manual ? appearance?.emoji : nil
        let color = appearance?.colorSource == .manual ? appearance?.color : nil
        self.init(
            name: row.name, environments: row.environments?.names ?? [], template: row.template ?? "",
            manual: emoji == nil && color == nil ? nil : LeoAppearanceManual(emoji: emoji, color: color)
        )
    }

    init(name: String, environments: [String], template: String, manual: LeoAppearanceManual?) {
        self.name = name
        self.environments = environments
        self.template = template
        self.manual = manual
    }
}

/// The Appearance tab's state for one machine: the ordered rules as a
/// draft with explicit Save and Revert. A rule's problem shows inline on
/// its row, whether found here or by the daemon (a 400 names the index); a
/// 409 re-reads the rules and asks whether to overwrite them or take
/// theirs. The preview resolves the draft against the machine's agents with
/// the same algorithm the daemon runs (`LeoAppearanceResolver`).
@MainActor final class LeoAppearanceSettingsModel: ObservableObject, LeoSettingsPane {
    enum Phase: Equatable {
        case loading
        /// The daemon doesn't advertise `agent_appearance`.
        case unsupported(version: String?)
        case ready
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        let id: UUID
        let rule: LeoAppearanceRule
    }

    struct PreviewEntry: Identifiable, Equatable {
        let name: String
        let appearance: LeoAgentAppearance?
        /// "Red from rule 1", "Teal, set on this agent", "No rule matches".
        let source: String
        var id: String { name }
    }

    static let capability = LeoDaemonFeatures.Feature.agentAppearance.rawValue

    @Published private(set) var phase = Phase.loading
    @Published private(set) var rows: [Row] = []
    @Published private(set) var saved: LeoAppearanceRulesDocument?
    @Published private(set) var isSaving = false
    @Published private(set) var isConflicted = false
    @Published private(set) var saveError: String?
    /// The daemon's 400, kept while that row is unedited.
    @Published private(set) var refusal: (rowID: UUID, reason: String)?
    @Published private(set) var harnessByTemplate: [String: String] = [:]

    private let client: any LeoConfigClient
    private let revisions: LeoConfigRevisionTracker
    private let agents: () -> [LeoAppearancePreviewAgent]

    init(client: any LeoConfigClient, revisions: LeoConfigRevisionTracker, agents: @escaping () -> [LeoAppearancePreviewAgent]) {
        self.client = client
        self.revisions = revisions
        self.agents = agents
    }

    var revision: String? { saved?.revision }
    var isDirty: Bool { saved.map { rows.map(\.rule) != $0.rules } ?? false }
    var canSave: Bool { isDirty && !isSaving && !isConflicted && rows.allSatisfy(\.rule.isValid) }

    // MARK: LeoSettingsPane

    var hasUnsavedChanges: Bool { isDirty }
    func discardChanges() { revert() }

    func reload(using client: any LeoConfigClient) async {
        guard let document = try? await client.appearanceRules() else { return }
        adopt(document, keepingDraft: isDirty)
    }

    // MARK: Loading

    func load() async {
        phase = .loading
        do {
            let info = try await client.versionInfo()
            guard info.supports(Self.capability) else {
                phase = .unsupported(version: info.version)
                return
            }
            adopt(try await client.appearanceRules(), keepingDraft: false)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        // Best effort: without it a template's harness reads as claude.
        if let templates = try? await client.collection("templates") {
            harnessByTemplate = Dictionary(
                templates.items.compactMap { item in item.effectiveHarness.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first }
            )
        }
    }

    private func adopt(_ document: LeoAppearanceRulesDocument, keepingDraft: Bool) {
        saved = document
        if !keepingDraft { rows = document.rules.map { Row(id: UUID(), rule: $0) } }
    }

    // MARK: Editing

    func add() {
        rows += [Row(id: UUID(), rule: LeoAppearanceRule(field: LeoAppearanceRule.Field.environments.rawValue, op: LeoAppearanceRule.Op.contains.rawValue, value: "", color: LeoAppearanceColor.blue.rawValue))]
    }

    func delete(_ id: UUID) {
        rows = rows.filter { $0.id != id }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var next = rows
        next.move(fromOffsets: source, toOffset: destination)
        rows = next
    }

    func update(_ id: UUID, _ rule: LeoAppearanceRule) {
        rows = rows.map { $0.id == id ? Row(id: id, rule: rule) : $0 }
        if refusal?.rowID == id { refusal = nil }
    }

    func revert() {
        rows = (saved?.rules ?? []).map { Row(id: UUID(), rule: $0) }
        refusal = nil
        saveError = nil
        isConflicted = false
    }

    /// The row's problem: the daemon's refusal while the row is unedited,
    /// else what's wrong with it here.
    func problem(at index: Int) -> String? {
        guard rows.indices.contains(index) else { return nil }
        if let refusal, refusal.rowID == rows[index].id { return refusal.reason }
        return rows[index].rule.problem
    }

    // MARK: Saving

    func save() async {
        guard let saved, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let sent = rows
        let base = revisions.resolve(saved.revision)
        do {
            let document = try await client.setAppearanceRules(sent.map(\.rule), ifMatch: base)
            revisions.recordWrite(from: base, to: document.revision)
            self.saved = document
            // Keep row identities across the save; the daemon echoes the order.
            if document.rules == sent.map(\.rule), rows == sent {
                rows = sent
            } else {
                rows = document.rules.map { Row(id: UUID(), rule: $0) }
            }
            saveError = nil
            refusal = nil
        } catch LeoAppearanceError.invalidRule(let index, let reason) where sent.indices.contains(index) {
            refusal = (sent[index].id, reason)
            saveError = nil
        } catch LeoConfigError.conflict {
            if let theirs = try? await client.appearanceRules() { adopt(theirs, keepingDraft: true) }
            isConflicted = true
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// After a conflict: write the draft over the rules just re-read.
    func overwriteTheirs() async {
        isConflicted = false
        await save()
    }

    /// After a conflict: drop the draft for the rules just re-read.
    func takeTheirs() {
        revert()
    }

    // MARK: Preview

    func matchCount(at index: Int) -> Int {
        guard rows.indices.contains(index) else { return 0 }
        let rule = rows[index].rule
        return agents().filter { rule.matches(facts($0)) }.count
    }

    var preview: [PreviewEntry] {
        let rules = rows.map(\.rule)
        return agents().map { agent in
            let appearance = LeoAppearanceResolver.resolve(rules: rules, facts: facts(agent), manual: agent.manual)
            return PreviewEntry(name: agent.name, appearance: appearance, source: Self.source(appearance))
        }
    }

    private func facts(_ agent: LeoAppearancePreviewAgent) -> LeoAppearanceFacts {
        LeoAppearanceFacts(
            name: agent.name, environments: agent.environments, template: agent.template, harness: harnessByTemplate[agent.template] ?? ""
        )
    }

    private static func source(_ appearance: LeoAgentAppearance?) -> String {
        guard let appearance else { return "No rule matches" }
        let parts = [
            appearance.color.map { LeoAgentAppearanceModel.sourceText($0.displayName, source: appearance.colorSource, rules: nil) },
            appearance.emoji.map { LeoAgentAppearanceModel.sourceText($0, source: appearance.emojiSource, rules: nil) },
        ]
        return parts.compactMap { $0 }.joined(separator: "; ")
    }
}
