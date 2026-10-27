import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The Appearance settings pane: a draft of the ordered rules with explicit
/// Save and Revert, inline problems per row (local, or the daemon's 400 on
/// its index), the config API's 409 flow, and a preview of every agent on
/// the machine resolved against the draft.
@MainActor
struct LeoAppearanceSettingsModelTests {
    private static let prod = LeoAppearanceRule(field: "environments", op: "contains", value: "prod", color: "red")
    private static let alfred = LeoAppearanceRule(field: "name", op: "glob", value: "alfred-*", color: "pink", emoji: "🎩")
    private static let agents = [
        LeoAppearancePreviewAgent(name: "olympus", environments: ["prod"], template: "ops", manual: nil),
        LeoAppearancePreviewAgent(name: "alfred-dj", environments: [], template: "assistant", manual: LeoAppearanceManual(emoji: "🎧", color: nil)),
        LeoAppearancePreviewAgent(name: "rocket", environments: [], template: "assistant", manual: nil),
    ]

    private func loaded(
        rules: [LeoAppearanceRule] = [prod, alfred], capabilities: [String] = [LeoConfigAPI.capability, "agent_appearance"]
    ) async -> (LeoAppearanceSettingsModel, LeoFakeConfigClient) {
        let fake = LeoFakeConfigClient(
            schema: LeoConfigSchema(resources: []), version: LeoDaemonVersionInfo(version: "0.70.0", capabilities: capabilities)
        )
        await fake.seedAppearance(agents: [LeoAppearanceFacts(name: "olympus", environments: ["prod"], template: "ops", harness: "")], rules: rules)
        let model = LeoAppearanceSettingsModel(client: fake, revisions: LeoConfigRevisionTracker(), agents: { Self.agents })
        await model.load()
        return (model, fake)
    }

    @Test func loadsTheRulesClean() async {
        let (model, _) = await loaded()
        #expect(model.phase == .ready)
        #expect(model.rows.map(\.rule) == [Self.prod, Self.alfred])
        #expect(!model.isDirty && !model.canSave)
    }

    @Test func olderDaemonIsUnsupported() async {
        let (model, fake) = await loaded(capabilities: [LeoConfigAPI.capability])
        #expect(model.phase == .unsupported(version: "0.70.0"))
        #expect(await !fake.calls.contains(.appearanceRules))
    }

    @Test func editsMakeItDirtyAndRevertUndoes() async {
        let (model, _) = await loaded()
        model.update(model.rows[0].id, LeoAppearanceRule(field: "environments", op: "contains", value: "prod", color: "orange"))
        #expect(model.isDirty && model.canSave)
        model.revert()
        #expect(!model.isDirty)
        #expect(model.rows.map(\.rule) == [Self.prod, Self.alfred])
    }

    @Test func addDeleteAndReorder() async {
        let (model, _) = await loaded()
        model.add()
        #expect(model.rows.count == 3)
        // A fresh rule has no value yet: Save waits for one.
        #expect(model.problem(at: 2) == "value is required")
        #expect(!model.canSave)
        model.delete(model.rows[2].id)
        #expect(!model.isDirty)
        model.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(model.rows.map(\.rule) == [Self.alfred, Self.prod])
        #expect(model.isDirty && model.canSave)
    }

    @Test func saveWritesTheDraftWithIfMatch() async {
        let (model, fake) = await loaded()
        let revision = model.revision
        model.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        await model.save()
        #expect(await fake.calls.last == .setAppearanceRules([Self.alfred, Self.prod], ifMatch: revision ?? ""))
        #expect(!model.isDirty)
        #expect(model.revision != revision)
    }

    @Test func daemonRefusalShowsOnItsRow() async {
        let (model, fake) = await loaded()
        model.update(model.rows[1].id, LeoAppearanceRule(field: "name", op: "glob", value: "alfred-*", color: "teal", emoji: "🎩"))
        await fake.failNextWrite(with: LeoAppearanceError.invalidRule(index: 1, reason: "emoji is not allowed here"))
        await model.save()
        #expect(model.problem(at: 1) == "emoji is not allowed here")
        #expect(model.problem(at: 0) == nil)
        #expect(model.isDirty)
        // Editing that row clears the daemon's word on it.
        model.update(model.rows[1].id, LeoAppearanceRule(field: "name", op: "glob", value: "alfred-*", color: "teal"))
        #expect(model.problem(at: 1) == nil)
    }

    @Test func conflictRereadsAndAsks() async throws {
        let (model, fake) = await loaded()
        let stale = model.revision ?? ""
        // Someone else saves meanwhile.
        _ = try? await fake.setAppearanceRules([Self.prod], ifMatch: stale)
        model.update(model.rows[0].id, LeoAppearanceRule(field: "environments", op: "contains", value: "prod", color: "orange"))
        await model.save()
        #expect(model.isConflicted)
        #expect(model.isDirty, "the draft is kept")
        #expect(model.revision != stale)

        await model.overwriteTheirs()
        #expect(!model.isConflicted)
        #expect(!model.isDirty)
        #expect(try await fake.appearanceRules().rules.first?.color == "orange")
    }

    @Test func conflictCanTakeTheirs() async {
        let (model, fake) = await loaded()
        _ = try? await fake.setAppearanceRules([Self.prod], ifMatch: model.revision ?? "")
        model.update(model.rows[0].id, LeoAppearanceRule(field: "environments", op: "contains", value: "prod", color: "orange"))
        await model.save()
        model.takeTheirs()
        #expect(!model.isConflicted && !model.isDirty)
        #expect(model.rows.map(\.rule) == [Self.prod])
    }

    @Test func previewResolvesTheDraftAndCountsMatches() async {
        let (model, _) = await loaded()
        #expect(model.matchCount(at: 0) == 1)
        #expect(model.matchCount(at: 1) == 1)
        let preview = Dictionary(uniqueKeysWithValues: model.preview.map { ($0.name, $0) })
        #expect(preview["olympus"]?.appearance == LeoAgentAppearance(emoji: nil, color: .red, emojiSource: nil, colorSource: .rule(0)))
        #expect(preview["olympus"]?.source == "Red from rule 1")
        #expect(preview["alfred-dj"]?.appearance == LeoAgentAppearance(emoji: "🎧", color: .pink, emojiSource: .manual, colorSource: .rule(1)))
        #expect(preview["rocket"]?.appearance == nil)
        #expect(preview["rocket"]?.source == "No rule matches")

        model.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        let moved = Dictionary(uniqueKeysWithValues: model.preview.map { ($0.name, $0) })
        #expect(moved["alfred-dj"]?.appearance?.colorSource == .rule(0))
    }

    @Test func paneHooksDiscardAndReload() async {
        let (model, fake) = await loaded()
        model.add()
        #expect(model.hasUnsavedChanges)
        model.discardChanges()
        #expect(!model.hasUnsavedChanges)
        _ = try? await fake.setAppearanceRules([Self.alfred], ifMatch: model.revision ?? "")
        await model.reload(using: fake)
        #expect(model.rows.map(\.rule) == [Self.alfred])
    }
}
