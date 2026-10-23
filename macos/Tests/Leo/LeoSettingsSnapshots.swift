import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

private let snapshotOutputDirectory = ProcessInfo.processInfo.environment["LEO_SETTINGS_SNAPSHOTS"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }

/// Renders the Settings window's schema form and pane states, light and dark,
/// to PNGs for a human to inspect. Only runs with
/// `LEO_SETTINGS_SNAPSHOTS=<output dir>`.
@MainActor @Suite(.enabled(if: snapshotOutputDirectory != nil), .timeLimit(.minutes(2)))
struct LeoSettingsSnapshots {
    private static let appearances: [(name: String, appearance: NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    /// One field of every control, with values, placeholders, a dirty row, an
    /// error, a warning, help text and an unknown type.
    private static var allFieldTypes: (resource: LeoConfigResource, document: LeoConfigDocument) {
        let model = LeoConfigHints(suggestions: ["claude-opus-5-5", "claude-sonnet-5-5"])
        let fields = [
            LeoConfigField(key: "workspace", label: "Workspace", help: "Directory agents start in.", group: "General", type: .string, constraints: LeoConfigConstraints(required: true)),
            LeoConfigField(key: "model", label: "Model", group: "General", type: .string, hintsByHarness: ["claude": model]),
            LeoConfigField(key: "harness", label: "Harness", group: "General", type: .enum, options: [
                LeoConfigOption(value: "", label: "Inherit"), LeoConfigOption(value: "claude", label: "Claude Code"), LeoConfigOption(value: "codex", label: "Codex"),
            ]),
            LeoConfigField(key: "parent", label: "Template", group: "General", type: .reference, references: "templates", emptyLabel: "none"),
            LeoConfigField(key: "system_prompt", label: "System prompt", group: "General", type: .string, multiline: true),
            LeoConfigField(key: "max_turns", label: "Max turns", group: "Limits", type: .int, constraints: LeoConfigConstraints(min: 1, max: 1000)),
            LeoConfigField(key: "idle_timeout", label: "Idle timeout", help: "Go duration, e.g. 30m.", group: "Limits", type: .duration, defaultValue: .string("30m")),
            LeoConfigField(key: "idle_suspend", label: "Suspend when idle", group: "Limits", type: .bool, nullable: true),
            LeoConfigField(key: "enabled", label: "Enabled", group: "Limits", type: .bool),
            LeoConfigField(key: "schedule", label: "Schedule", group: "Schedule", type: .string, format: "cron"),
            LeoConfigField(key: "environments", label: "Environments", group: "Lists", type: .list),
            LeoConfigField(key: "env", label: "Variables", warning: "Values are stored in leo.yaml in plain text.", group: "Lists", type: .map),
            LeoConfigField(key: "token", label: "Token", group: "Secrets", type: .secret),
            LeoConfigField(key: "settings", label: "Settings", help: "YAML mapping passed to the harness.", group: "Secrets", type: .yaml),
            LeoConfigField(key: "tint", label: "Tint", group: "Other", type: .unknown("color")),
            LeoConfigField(key: "isolation", label: "Isolation", group: "Advanced", advanced: true, type: .enum, options: [LeoConfigOption(value: "", label: "None")]),
        ]
        let values: [String: LeoConfigValue] = [
            "workspace": .string("~/code"), "harness": .string("claude"), "parent": .string("coder"),
            "system_prompt": .string("Be brief.\nShip small diffs."), "max_turns": .null, "idle_suspend": .null, "enabled": .bool(true),
            "schedule": .string("0 3 * * *"), "environments": .list([.string("work"), .string("secrets")]),
            "env": .map(["API_BASE": "https://example.test", "FOO": "bar"]), "token": .secret(isSet: true), "settings": .string("theme: dark\n"),
        ]
        let document = LeoConfigDocument(
            revision: "r", name: "coder", values: values, inherited: ["model": .string("claude-opus-5-5"), "idle_suspend": .bool(true)], effectiveHarness: "claude"
        )
        return (LeoConfigResource(key: "templates", kind: .collection, fields: fields), document)
    }

    @Test func allFieldTypes() throws {
        let directory = try #require(snapshotOutputDirectory)
        let (resource, document) = Self.allFieldTypes
        var draft = LeoConfigDraft(
            document: document, validator: LeoConfigValidator(resource: resource, references: ["templates": ["coder", "reviewer"]])
        )
        draft.set("workspace", .string("~/elsewhere"))
        draft.set("max_turns", .int(0))
        let sections = LeoConfigFormLayout.sections(
            resource: resource, harnesses: [:], draft: draft, references: ["templates": ["coder", "reviewer"]], webLink: URL(string: "https://leo.example.com/config")
        )
        let form = LeoSchemaForm(
            sections: sections, formErrors: ["templates.old: workspace is required"], cronPreviews: ["schedule": .valid("At 03:00 every day")],
            set: { _, _ in }, revert: { _ in }
        )
        try Self.write(form, named: "allFieldTypes", size: NSSize(width: 640, height: 1500), to: directory)
    }

    @Test func paneStates() throws {
        let directory = try #require(snapshotOutputDirectory)
        try Self.write(
            LeoDisconnectedPaneNotice(machine: "dionysus", status: .failed("ssh: connect to host dionysus port 22: Connection refused"), reconnect: {}),
            named: "paneDisconnected", size: NSSize(width: 640, height: 260), to: directory
        )
        try Self.write(LeoTooOldPaneNotice(machine: "dionysus", running: "0.40.0"), named: "paneTooOld", size: NSSize(width: 640, height: 220), to: directory)
    }

    // MARK: Templates pane

    private static func templatesModel(secretEnv: Bool = false) async throws -> (LeoConfigCollectionModel, LeoFakeConfigClient) {
        let fake = try LeoConfigGolden.client(secretEnv: secretEnv)
        let model = LeoConfigCollectionModel(resource: "templates", client: fake, revisions: LeoConfigRevisionTracker(), machineHost: "dionysus")
        await model.load()
        return (model, fake)
    }

    private static func templatesPane(_ model: LeoConfigCollectionModel) -> some View {
        let restart = LeoConfigRestartActions(restartService: {}, restartAgents: {})
        return LeoConfigCollectionView(model: model, machine: "dionysus", restart: restart)
    }

    private static let templatesSize = NSSize(width: 820, height: 760)

    @Test func templates() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let (model, _) = try await Self.templatesModel()
        try Self.write(Self.templatesPane(model), named: "templates", size: Self.templatesSize, to: directory)
    }

    @Test func templatesEditedWithAFieldErrorAndARestartPrompt() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let (model, _) = try await Self.templatesModel()
        model.set("model", .string("sonnet"))
        await model.save()
        model.set("max_turns", .int(-1))
        model.set("workspace", .string("~/code/leo"))
        try Self.write(Self.templatesPane(model), named: "templatesEdited", size: Self.templatesSize, to: directory)
    }

    @Test func templatesConflict() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let (model, fake) = try await Self.templatesModel()
        let revision = try await fake.collection("templates").revision
        _ = try await fake.update("web", name: nil, patch: ["port": .int(9000)], ifMatch: revision)
        model.set("model", .string("sonnet"))
        await model.save()
        try Self.write(Self.templatesPane(model), named: "templatesConflict", size: Self.templatesSize, to: directory)
    }

    @Test func templatesEnvWithASecretVariable() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let (model, _) = try await Self.templatesModel(secretEnv: true)
        try Self.write(Self.templatesPane(model), named: "templatesEnvSecret", size: NSSize(width: 820, height: 2300), to: directory)
    }

    @Test func templatesAddSheet() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let (model, _) = try await Self.templatesModel()
        let sheet = LeoNameSheet(
            title: "New template", confirmTitle: "Add", name: "coder", validate: { model.nameError($0) }, submit: { _ in }, cancel: {}
        )
        try Self.write(sheet, named: "templatesAddSheet", size: NSSize(width: 360, height: 150), to: directory)
    }

    // MARK: Tasks pane

    private static func tasksModel(page: LeoTasksSettingsModel.Page = .settings) async throws -> LeoTasksSettingsModel {
        let fake = try LeoConfigGolden.client(tasks: LeoConfigGolden.taskData())
        let previewer = LeoCronPreviewer(sleep: { _ in }, fetch: { expression in
            expression.split(separator: " ").count == 5
                ? LeoCronPreview(valid: true, description: "Every hour, on the hour", error: nil)
                : LeoCronPreview(valid: false, description: "", error: "Expected 5 fields (minute hour day month weekday), got \(expression.split(separator: " ").count)")
        })
        let model = LeoTasksSettingsModel(client: fake, revisions: LeoConfigRevisionTracker(), machineHost: "dionysus", previewer: previewer)
        await model.load()
        model.setPage(page)
        await model.settled()
        return model
    }

    private static let tasksSize = NSSize(width: 900, height: 720)

    @Test func tasks() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let model = try await Self.tasksModel()
        await model.runNow("heartbeat")
        try Self.write(LeoTasksView(model: model, machine: "dionysus"), named: "tasks", size: Self.tasksSize, to: directory)
    }

    @Test func tasksEditedWithAnInvalidSchedule() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let model = try await Self.tasksModel()
        model.collection.set("schedule", .string("0 * *"))
        model.collection.set("model", .string("sonnet"))
        await model.settled()
        try Self.write(LeoTasksView(model: model, machine: "dionysus"), named: "tasksEdited", size: Self.tasksSize, to: directory)
    }

    @Test func tasksPrompt() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let model = try await Self.tasksModel(page: .prompt)
        model.setPromptText("Check the thing.\n\nThen, if anything looks off, post a short note in the ops thread.\n")
        try Self.write(LeoTasksView(model: model, machine: "dionysus"), named: "tasksPrompt", size: Self.tasksSize, to: directory)
    }

    @Test func tasksPromptMoved() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let fake = try LeoConfigGolden.client(tasks: LeoConfigGolden.taskData())
        let model = LeoTasksSettingsModel(client: fake, revisions: LeoConfigRevisionTracker(), machineHost: "dionysus", previewer: LeoCronPreviewer(sleep: { _ in }, fetch: { try await fake.cronPreview($0) }))
        await model.load()
        model.setPage(.prompt)
        await model.settled()
        model.setPromptText("Check the thing.\n\nThen, if anything looks off, post a short note in the ops thread.\n")
        await fake.externalChange("tasks", name: "heartbeat", values: ["prompt_file": .string("notes.md")])
        await model.reload(using: fake)
        try Self.write(LeoTasksView(model: model, machine: "dionysus"), named: "tasksPromptMoved", size: Self.tasksSize, to: directory)
    }

    @Test func tasksHistory() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let model = try await Self.tasksModel(page: .history)
        try Self.write(LeoTasksView(model: model, machine: "dionysus"), named: "tasksHistory", size: Self.tasksSize, to: directory)
    }

    @Test func tasksAddSheet() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let model = try await Self.tasksModel()
        let sheet = LeoTaskAddSheet(model: model, submit: { _, _ in }, cancel: {})
        try Self.write(sheet, named: "tasksAddSheet", size: NSSize(width: 420, height: 184), to: directory)
    }

    // MARK: Environments pane

    private static func environmentsModel() async throws -> LeoConfigCollectionModel {
        let fake = try LeoConfigGolden.client(secretEnvironment: true)
        let model = LeoConfigCollectionModel(resource: "environments", client: fake, revisions: LeoConfigRevisionTracker(), machineHost: "dionysus")
        await model.load()
        model.select("work")
        return model
    }

    private static let environmentsSize = NSSize(width: 820, height: 460)

    @Test func environments() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let model = try await Self.environmentsModel()
        try Self.write(Self.templatesPane(model), named: "environments", size: Self.environmentsSize, to: directory)
    }

    @Test func environmentsEditedWithARestartPrompt() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let model = try await Self.environmentsModel()
        model.set("env", model.draft?.value(at: "env").replacingEnvEntries(["WORK_URL": "http://work.local", "REGION": "eu"]) ?? .null)
        await model.save()
        model.set("env", model.draft?.value(at: "env").settingEnvSecret("WORK_TOKEN", to: .secretReplace("new")) ?? .null)
        try Self.write(Self.templatesPane(model), named: "environmentsEdited", size: Self.environmentsSize, to: directory)
    }

    @Test func environmentsAddSheet() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let model = try await Self.environmentsModel()
        let sheet = LeoNameSheet(
            title: "New environment", confirmTitle: "Add", name: "", validate: { model.nameError($0) }, submit: { _ in }, cancel: {}
        )
        try Self.write(sheet, named: "environmentsAddSheet", size: NSSize(width: 360, height: 150), to: directory)
    }

    // MARK: Delegation pane

    private static func delegationModel(_ document: LeoDelegationDocument? = LeoDelegationFixtures.document()) async throws -> (LeoDelegationSettingsModel, LeoFakeConfigClient) {
        let fake = try LeoConfigGolden.client(delegation: document)
        let model = LeoDelegationSettingsModel(client: fake, revisions: LeoConfigRevisionTracker(), machineHost: "dionysus")
        await model.load()
        return (model, fake)
    }

    private static func delegationPane(_ model: LeoDelegationSettingsModel) -> some View {
        LeoDelegationView(model: model, machine: "dionysus", restart: LeoConfigRestartActions(restartService: {}, restartAgents: {}))
    }

    @Test func delegation() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let (model, _) = try await Self.delegationModel()
        try Self.write(Self.delegationPane(model), named: "delegation", size: NSSize(width: 900, height: 760), to: directory)
    }

    /// Six profiles by eight roles, once at a width that shows the whole grid and once at the window's, where it scrolls sideways.
    @Test func delegationWide() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let (model, _) = try await Self.delegationModel(LeoDelegationFixtures.wide())
        try Self.write(Self.delegationPane(model), named: "delegationWide", size: NSSize(width: 1500, height: 1500), to: directory)
        try Self.write(Self.delegationPane(model), named: "delegationWideNarrow", size: NSSize(width: 900, height: 1500), to: directory)
    }

    @Test func delegationConflictAndRestartPrompt() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let (model, fake) = try await Self.delegationModel()
        model.beginCellEdit(profile: "fast", role: "coder")
        model.setCellEffort("low")
        await model.saveCellEdit()
        model.beginCellEdit(profile: "deep", role: "qa")
        model.setCellEffort("max")
        await fake.externalDelegationChange(profile: "deep", role: "qa", target: LeoDelegationTarget(template: "coder"))
        await model.saveCellEdit()
        try Self.write(Self.delegationPane(model), named: "delegationConflict", size: NSSize(width: 900, height: 760), to: directory)
    }

    @Test func delegationCellPopover() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let (model, _) = try await Self.delegationModel()
        model.beginCellEdit(profile: "deep", role: "qa")
        model.setCellEffort("ludicrous")
        await model.saveCellEdit()
        try Self.write(LeoDelegationCellPopover(model: model), named: "delegationCellPopover", size: NSSize(width: 340, height: 300), to: directory)
        model.beginCellEdit(profile: "deep", role: "qa")
        model.setCellTemplate("")
        try Self.write(LeoDelegationCellPopover(model: model), named: "delegationCellPopoverRemove", size: NSSize(width: 340, height: 300), to: directory)
    }

    @Test func delegationPreviewSheet() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let (model, _) = try await Self.delegationModel()
        await model.requestActivate("deep")
        try Self.write(LeoDelegationPreviewSheet(model: model), named: "delegationPreview", size: NSSize(width: 460, height: 260), to: directory)
        let (back, _) = try await Self.delegationModel(LeoDelegationFixtures.document(active: "deep"))
        await back.requestActivate("fast")
        try Self.write(LeoDelegationPreviewSheet(model: back), named: "delegationPreviewMissing", size: NSSize(width: 460, height: 260), to: directory)
    }

    @Test func delegationNotConfiguredAndAddRole() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let (model, _) = try await Self.delegationModel(nil)
        try Self.write(Self.delegationPane(model), named: "delegationNotConfigured", size: NSSize(width: 700, height: 360), to: directory)
        let (configured, _) = try await Self.delegationModel()
        try Self.write(LeoDelegationAddRoleSheet(model: configured, close: {}), named: "delegationAddRole", size: NSSize(width: 380, height: 220), to: directory)
    }

    // MARK: Defaults pane

    private static let restartActions = LeoConfigRestartActions(restartService: {}, restartAgents: {})
    private static let defaultsSize = NSSize(width: 820, height: 760)

    private static func defaultsModel() async throws -> (LeoConfigSingletonModel, LeoFakeConfigClient) {
        let fake = try LeoConfigGolden.client()
        let model = LeoConfigSingletonModel(resource: "defaults", client: fake, revisions: LeoConfigRevisionTracker(), machineHost: "dionysus")
        await model.load()
        return (model, fake)
    }

    @Test func defaults() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let (model, _) = try await Self.defaultsModel()
        try Self.write(
            LeoConfigSingletonView(model: model, machine: "dionysus", restart: Self.restartActions), named: "defaults", size: Self.defaultsSize, to: directory
        )
    }

    @Test func defaultsEditedWithAFieldErrorAndARestartPrompt() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let (model, _) = try await Self.defaultsModel()
        model.set("model", .string("opus"))
        await model.save()
        model.set("max_turns", .int(-1))
        model.set("environments", .list([.string("base"), .string("work")]))
        try Self.write(
            LeoConfigSingletonView(model: model, machine: "dionysus", restart: Self.restartActions), named: "defaultsEdited", size: Self.defaultsSize, to: directory
        )
    }

    @Test func defaultsConflict() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let (model, fake) = try await Self.defaultsModel()
        await fake.externalChange("defaults", values: ["max_turns": .int(3)])
        model.set("model", .string("opus"))
        await model.save()
        try Self.write(
            LeoConfigSingletonView(model: model, machine: "dionysus", restart: Self.restartActions), named: "defaultsConflict", size: Self.defaultsSize, to: directory
        )
    }

    // MARK: Daemon pane

    private static let daemonSize = NSSize(width: 820, height: 640)

    private static func daemonModel(_ section: LeoDaemonSettingsModel.Section) async throws -> LeoDaemonSettingsModel {
        let model = LeoDaemonSettingsModel(client: try LeoConfigGolden.client(), revisions: LeoConfigRevisionTracker(), machineHost: "dionysus")
        await model.load()
        model.section = section
        return model
    }

    @Test func daemonWebWithItsLockoutWarnings() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let model = try await Self.daemonModel(.web)
        try Self.write(LeoDaemonView(model: model, machine: "dionysus"), named: "daemonWeb", size: Self.daemonSize, to: directory)
    }

    @Test func daemonWebEditedWithARestartPrompt() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let model = try await Self.daemonModel(.web)
        model.web.set("port", .int(9000))
        await model.web.save()
        model.web.set("allowed_hosts", .list([.string("leo.example.com")]))
        model.client.set("default_host", .string(""))
        try Self.write(LeoDaemonView(model: model, machine: "dionysus"), named: "daemonWebEdited", size: Self.daemonSize, to: directory)
    }

    @Test func daemonClient() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let model = try await Self.daemonModel(.client)
        await model.hosts.add(name: "staging")
        try Self.write(LeoDaemonView(model: model, machine: "dionysus"), named: "daemonClient", size: NSSize(width: 820, height: 320), to: directory)
    }

    @Test func daemonHosts() async throws {
        let directory = try #require(snapshotOutputDirectory)
        let model = try await Self.daemonModel(.hosts)
        await model.hosts.add(name: "staging")
        model.hosts.select("remote")
        model.hosts.set("ssh_args", .list([.string("-p"), .string("2222")]))
        try Self.write(LeoDaemonView(model: model, machine: "dionysus"), named: "daemonHosts", size: Self.daemonSize, to: directory)
    }

    // MARK: Rendering

    private static func write(_ view: some View, named name: String, size: NSSize, to directory: URL) throws {
        for (label, appearance) in appearances {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).frame(width: size.width, height: size.height))
            let window = KeyableWindow(
                contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderBack(nil)
            window.makeKey()
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let data = try #require(Self.png(of: host))
            try data.write(to: directory.appending(path: "\(name)-\(label).png"))
            window.close()
        }
    }

    private static func png(of view: NSView) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * 2, pixelsHigh: Int(view.bounds.height) * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// A borderless window that can be key, so controls draw as active.
    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }
}
