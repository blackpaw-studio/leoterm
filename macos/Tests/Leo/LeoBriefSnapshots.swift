import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

private let briefSnapshotDirectory = ProcessInfo.processInfo.environment["LEO_BRIEF_SNAPSHOTS"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }

/// Renders the agent brief surfaces (row line, inbox detail, Settings switch),
/// light and dark, to PNGs for a human to inspect. Only runs with
/// `LEO_BRIEF_SNAPSHOTS=<output dir>`.
@MainActor @Suite(.enabled(if: briefSnapshotDirectory != nil), .timeLimit(.minutes(2)))
struct LeoBriefSnapshots {
    private static let appearances: [(name: String, appearance: NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    private static let brief = LeoAgentBrief(
        goal: "Ship the agent brief to both apps",
        status: "Waiting on review of the Mac row precedence",
        decisions: ["Brief replaces the idle detail line, never the live tool line", "Settings switch lives in the Daemon pane"],
        open: ["iOS chat header collapse state", "Daemon release advertising agent_brief"],
        updatedAt: Date().addingTimeInterval(-12 * 60)
    )

    @Test func rows() throws {
        let directory = try #require(briefSnapshotDirectory)
        func row(
            _ name: String, brief: LeoAgentBrief?, attention: LeoAttentionBadge?, metadata: LeoAgentMetadata? = nil, lastTurn: LeoTurnPreview? = nil
        ) -> LeoAgentRow {
            LeoAgentRow(
                host: .local, name: name, template: "claude", status: .running, activity: .idle, actionDetail: nil,
                workspace: "/tmp/\(name)", attention: attention, startedAt: "s", metadata: metadata, lastTurn: lastTurn, brief: brief
            )
        }
        let turn = LeoTurnPreview(text: "Fixed the bug", outcome: .completed)
        let working = LeoAgentMetadata(lastActiveAt: nil, isWorking: true, task: nil, usage: nil, tool: "Edit")
        let rows = VStack(spacing: 0) {
            ForEach([
                row("idle-with-brief", brief: Self.brief, attention: nil),
                row("idle-no-brief", brief: nil, attention: nil),
                row("idle-goal-only", brief: LeoAgentBrief(goal: "No status yet"), attention: nil),
                row("finished-with-brief", brief: Self.brief, attention: .finished, lastTurn: turn),
                row("finished-no-brief", brief: nil, attention: .finished, lastTurn: turn),
                row("working-tool-wins", brief: Self.brief, attention: .working, metadata: working),
                row("working-brief", brief: Self.brief, attention: .working),
            ]) { row in
                LeoAgentRowContent(row: row, error: nil, isSelected: false, isPending: false, nameHighlights: [])
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
        }
        try Self.write(rows, named: "row", size: NSSize(width: 300, height: 340), to: directory)
    }

    @Test func inboxDetail() throws {
        let directory = try #require(briefSnapshotDirectory)
        let now = Date()
        func item(_ kind: LeoInboxKind, brief: LeoAgentBrief) -> LeoInboxItem {
            LeoInboxItem(
                id: LeoAgentID(host: .local, name: "leoterm"), kind: kind, isUnread: true, agent: "leoterm", machine: "This Mac",
                projectLabel: nil, at: now.addingTimeInterval(-300), brief: brief
            )
        }
        let stale = LeoAgentBrief(
            goal: Self.brief.goal, status: Self.brief.status, decisions: Self.brief.decisions, open: [], updatedAt: now.addingTimeInterval(-3 * 86_400)
        )
        let model = LeoInboxModel()
        for (name, value) in [
            ("inboxBlocked", item(.permission(tool: "Bash", detail: "nomad job run x", input: nil), brief: Self.brief)),
            ("inboxFinishedStale", item(.finished(result: "Booked Thursday."), brief: stale)),
        ] {
            try Self.write(LeoInboxDetail(model: model, item: value, actions: LeoInboxActions()), named: name, size: NSSize(width: 720, height: 520), to: directory)
        }
    }

    @Test func settingsSwitch() async throws {
        let directory = try #require(briefSnapshotDirectory)
        let fake = try LeoConfigGolden.client(briefs: true)
        let model = LeoDaemonSettingsModel(client: fake, revisions: LeoConfigRevisionTracker(), machineHost: "dionysus")
        await model.load()
        await model.setBriefsEnabled(true)
        try Self.write(LeoDaemonView(model: model, machine: "dionysus"), named: "settingsBriefs", size: NSSize(width: 820, height: 340), to: directory)
    }

    // MARK: Rendering

    private static func write(_ view: some View, named name: String, size: NSSize, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appending(path: "\(name)-\(label).png"))
            window.close()
        }
    }

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }
}
