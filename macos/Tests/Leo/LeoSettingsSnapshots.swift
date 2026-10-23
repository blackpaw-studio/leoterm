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
            sections: sections, formErrors: ["templates.old: workspace is required"], cronPreviews: ["schedule": "At 03:00 every day"],
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
