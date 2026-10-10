import Foundation
import Testing

@testable import Ghostty

/// Row metadata (B-011, D-074): what `/state` reports per agent, when an
/// entry may attach to a row, and how the row draws it.
struct LeoAgentMetadataTests {
    private static let utc = TimeZone(identifier: "UTC")!
    private static let now = date("2026-09-24T15:30:00Z")

    // MARK: Decoding

    @Test func stateDecodesStartedAtAsTheIncarnationIdentity() throws {
        let json = #"{"name":"alpha","status":"running","activity":"idle","started_at":"2026-09-23T08:50:25.297303-04:00","last_activity_at":"2026-09-23T21:54:32-04:00","current_action":{"kind":"pane","detail":"Reading files"}}"#
        let agent = try JSONDecoder().decode(LeoObservedAgent.self, from: Data(json.utf8))
        #expect(agent.startedAt == "2026-09-23T08:50:25.297303-04:00")
        #expect(agent.lastActivityAt == "2026-09-23T21:54:32-04:00")
    }

    // MARK: Index

    @Test func indexKeepsReportedFieldsOnly() throws {
        let entries = LeoAgentMetadataIndex(state: [
            observed("alpha", startedAt: "s1", lastActivityAt: "2026-09-23T21:54:32-04:00", detail: "Reading files"),
            observed("beta", startedAt: "s2", lastActivityAt: nil, detail: nil),
            observed("gamma", startedAt: "s3", lastActivityAt: "not a date", detail: "   ")
        ])
        let alpha = try #require(entries.metadata(name: "alpha", startedAt: "s1"))
        #expect(alpha.lastActiveAt == Self.date("2026-09-24T01:54:32Z"))
        #expect(alpha.task == "Reading files")
        #expect(entries.metadata(name: "beta", startedAt: "s2") == nil, "nothing reported, nothing attached")
        #expect(entries.metadata(name: "gamma", startedAt: "s3") == nil, "unparseable time and blank task are omitted")
    }

    @Test func indexParsesFractionalSeconds() throws {
        let entries = LeoAgentMetadataIndex(state: [observed("alpha", startedAt: "s1", lastActivityAt: "2026-09-23T08:50:25.297303-04:00")])
        let lastActiveAt = try #require(entries.metadata(name: "alpha", startedAt: "s1")?.lastActiveAt)
        #expect(abs(lastActiveAt.timeIntervalSince(Self.date("2026-09-23T12:50:25Z")) - 0.297303) < 0.001)
    }

    @Test func taskTextIsSanitized() throws {
        let entries = LeoAgentMetadataIndex(state: [observed("alpha", startedAt: "s1", detail: "Edit\u{202E}gnp.exe\nnext\u{200B}line")])
        let task = try #require(entries.metadata(name: "alpha", startedAt: "s1")?.task)
        #expect(task == LeoSFTPServerText.sanitized("Edit\u{202E}gnp.exe\nnext\u{200B}line"))
        #expect(!task.contains("\n"))
        #expect(!task.unicodeScalars.contains("\u{202E}"))
    }

    // B-260: kind "tool" shows the tool's name, never its arguments.
    @Test func toolActionYieldsToolNameWithoutArguments() throws {
        let entries = LeoAgentMetadataIndex(state: [observed("alpha", startedAt: "s1", kind: "tool", detail: "Read ~/a.go")])
        let metadata = try #require(entries.metadata(name: "alpha", startedAt: "s1"))
        #expect(metadata.tool == "Read")
        #expect(metadata.task == nil)
    }

    @Test(arguments: [("Bash", "Bash"), ("mcp__srv__do x y", "mcp__srv__do"), ("  Edit   a b ", "Edit")])
    func toolNameIsTheFirstToken(detail: String, expected: String) {
        #expect(LeoAgentMetadata.toolName(fromDetail: detail) == expected)
    }

    @Test func blankToolDetailYieldsNothing() {
        #expect(LeoAgentMetadata.toolName(fromDetail: "") == nil)
        #expect(LeoAgentMetadata.toolName(fromDetail: " \t ") == nil)
        let entries = LeoAgentMetadataIndex(state: [observed("alpha", startedAt: "s1", kind: "tool", detail: "   ")])
        #expect(entries.metadata(name: "alpha", startedAt: "s1") == nil)
    }

    @Test func toolNameIsSanitized() {
        #expect(LeoAgentMetadata.toolName(fromDetail: "\u{1B}[31mBash\u{1B}[0m make") == "Bash", "CSI escapes are stripped")
        #expect(LeoAgentMetadata.toolName(fromDetail: "\u{1B}]0;title\u{07}Read x") == "Read", "OSC escapes are stripped")
        #expect(LeoAgentMetadata.toolName(fromDetail: "\u{1B}]8;;http://x\u{1B}\\Edit\u{1B}]8;;\u{1B}\\ y") == "Edit")
        #expect(LeoAgentMetadata.toolName(fromDetail: "Ba\u{202E}sh\nmake") == "Bash", "bidi controls are dropped")
        #expect(LeoAgentMetadata.toolName(fromDetail: "Gr\u{0}ep\u{7} x") == "Grep", "control characters are dropped")
        #expect(LeoAgentMetadata.toolName(fromDetail: "\u{1B}[31m\u{1B}[0m") == nil)
    }

    @Test(arguments: ["pane", nil, "future"] as [String?])
    func otherKindsKeepTheTaskLine(kind: String?) throws {
        let entries = LeoAgentMetadataIndex(state: [observed("alpha", startedAt: "s1", kind: kind, detail: "Reading files now")])
        let metadata = try #require(entries.metadata(name: "alpha", startedAt: "s1"))
        #expect(metadata.task == "Reading files now")
        #expect(metadata.tool == nil)
    }

    @Test func anEntryAttachesOnlyToTheIncarnationThatReportedIt() {
        let entries = LeoAgentMetadataIndex(state: [observed("alpha", startedAt: "s1", detail: "Reading")])
        #expect(entries.metadata(name: "alpha", startedAt: "s1")?.task == "Reading")
        #expect(entries.metadata(name: "alpha", startedAt: "s2") == nil, "a recreated namesake")
        #expect(entries.metadata(name: "alpha", startedAt: nil) == nil, "no identity, no attachment")
        #expect(entries.metadata(name: "beta", startedAt: "s1") == nil)
    }

    @Test func usageAttachesOnlyToSameIncarnation() {
        let usage = LeoAgentUsage(session: LeoUsageTotals(tokens: 10, costUSD: 0.1))
        let entries = LeoAgentMetadataIndex(state: [observed("alpha", startedAt: "s1", usage: usage)])
        #expect(entries.metadata(name: "alpha", startedAt: "s1")?.usage == usage, "usage alone earns an entry")
        #expect(entries.metadata(name: "alpha", startedAt: "s2")?.usage == nil, "a different started_at gets no usage")
        #expect(LeoAgentMetadataIndex(state: [observed("alpha", startedAt: nil, usage: usage)]).metadata(name: "alpha", startedAt: nil) == nil)
    }

    @Test func anEntryWithoutIdentityNeverAttaches() {
        let entries = LeoAgentMetadataIndex(state: [observed("alpha", startedAt: nil, detail: "Reading")])
        #expect(entries.metadata(name: "alpha", startedAt: nil) == nil)
    }

    @Test func attachingOverlaysMatchingRowsAndClearsTheRest() {
        let entries = LeoAgentMetadataIndex(state: [observed("alpha", startedAt: "s1", detail: "Reading")])
        let rows = entries.attach(to: [row("alpha", startedAt: "s1"), row("beta", startedAt: "s9")])
        #expect(rows[0].metadata?.task == "Reading")
        #expect(rows[1].metadata == nil)
        #expect(rows[0].startedAt == "s1")
    }

    // MARK: Relative time

    @Test func relativeTimeLabels() {
        let cases: [(TimeInterval, String)] = [
            (0, "now"), (59, "now"), (-120, "now"), (60, "1m"), (5 * 60 + 30, "5m"), (59 * 60 + 59, "59m"),
            (3600, "1h"), (3 * 3600 + 1, "3h"), (23 * 3600 + 3599, "23h")
        ]
        for (ago, label) in cases {
            #expect(LeoRelativeTime.label(since: Self.now.addingTimeInterval(-ago), now: Self.now, timeZone: Self.utc, locale: .init(identifier: "en_US")) == label, "\(ago)s ago")
        }
    }

    @Test func relativeTimeFallsBackToTheDateAfterADay() {
        let label = { (date: Date) in LeoRelativeTime.label(since: date, now: Self.now, timeZone: Self.utc, locale: .init(identifier: "en_US")) }
        #expect(label(Self.date("2026-09-21T10:00:00Z")) == "Sep 21")
        #expect(label(Self.now.addingTimeInterval(-24 * 3600)) == "Sep 23")
        #expect(label(Self.date("2025-12-30T10:00:00Z")) == "Dec 30, 2025")
    }

    @Test func spokenRelativeTime() {
        let spoken = { (ago: TimeInterval) in
            LeoRelativeTime.spokenLabel(since: Self.now.addingTimeInterval(-ago), now: Self.now, timeZone: Self.utc, locale: .init(identifier: "en_US"))
        }
        #expect(spoken(10) == "active now")
        #expect(spoken(60) == "last active 1 minute ago")
        #expect(spoken(5 * 60) == "last active 5 minutes ago")
        #expect(spoken(3 * 3600) == "last active 3 hours ago")
        #expect(spoken(3 * 86400) == "last active Sep 21")
    }

    // MARK: Row presentation

    @Test func taskComesFromMetadataNotTheEventDrivenDetail() {
        let fromEvents = LeoAgentRow(host: .local, name: "alpha", template: nil, status: .running, activity: .working, actionDetail: "event detail")
        #expect(LeoAgentRowPresentation(row: fromEvents, error: nil, now: Self.now).detail == .fallback(LeoAgentRowPresentation.emptyFallback))
        let metadata = LeoAgentMetadata(lastActiveAt: nil, isWorking: false, task: "snapshot task")
        #expect(LeoAgentRowPresentation(row: row("alpha", template: nil, metadata: metadata), error: nil, now: Self.now).detail == .task("snapshot task"))
    }

    // MARK: Helpers

    private static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func observed(
        _ name: String, startedAt: String?, lastActivityAt: String? = nil, kind: String? = "pane",
        detail: String? = nil, usage: LeoAgentUsage? = nil
    ) -> LeoObservedAgent {
        LeoObservedAgent(
            name: name, status: .running, activity: .idle, currentAction: detail.map { .init(kind: kind, detail: $0) },
            lastActivityAt: lastActivityAt, startedAt: startedAt, usage: usage
        )
    }

    private func row(
        _ name: String, template: String? = nil, attention: LeoAttentionBadge? = nil, startedAt: String? = nil,
        metadata: LeoAgentMetadata? = nil
    ) -> LeoAgentRow {
        LeoAgentRow(
            host: .local, name: name, template: template, status: .running, activity: .idle, actionDetail: nil,
            attention: attention, startedAt: startedAt, metadata: metadata
        )
    }
}
