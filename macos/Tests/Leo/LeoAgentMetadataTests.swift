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

    @Test func subtitleAppendsTheRelativeTime() {
        let metadata = LeoAgentMetadata(lastActiveAt: Self.now.addingTimeInterval(-300), isWorking: false, task: nil)
        let presentation = LeoAgentRowPresentation(
            row: row("alpha", template: "claude", attention: .needsInput, metadata: metadata), isSelected: false,
            now: Self.now, timeZone: Self.utc, locale: .init(identifier: "en_US")
        )
        #expect(presentation.subtitle?.text == "claude · Needs Input · 5m")
        #expect(presentation.subtitle?.lastActive == "5m")
    }

    @Test func theTimeNeverTruncatesAndTheTemplateGivesWayFirst() throws {
        let metadata = LeoAgentMetadata(lastActiveAt: Self.now.addingTimeInterval(-300), isWorking: false, task: nil)
        let presentation = LeoAgentRowPresentation(
            row: row("alpha", template: "claude", attention: .needsInput, metadata: metadata), isSelected: false, now: Self.now
        )
        let segments = try #require(presentation.subtitle?.segments)
        #expect(segments.map(\.text) == ["claude", "Needs Input", "5m"])
        #expect(segments.map(\.hasSeparator) == [false, true, true])
        #expect(segments.map(\.truncation) == [.first, .second, .never])
        #expect(LeoAgentRowPresentation.Subtitle.Truncation.first.layoutPriority
            < LeoAgentRowPresentation.Subtitle.Truncation.second.layoutPriority)
        #expect(presentation.subtitle?.accessibilityLabel == "claude, last active 5 minutes ago")
    }

    @Test func segmentsOmitWhateverIsMissing() throws {
        let metadata = LeoAgentMetadata(lastActiveAt: Self.now.addingTimeInterval(-7200), isWorking: false, task: nil)
        let timeOnly = try #require(LeoAgentRowPresentation(row: row("alpha", template: nil, metadata: metadata), isSelected: false, now: Self.now).subtitle)
        #expect(timeOnly.segments.map(\.text) == ["2h"])
        #expect(timeOnly.segments.map(\.hasSeparator) == [false])
        let noTime = try #require(LeoAgentRowPresentation(row: row("alpha", template: "claude", attention: .finished), isSelected: false).subtitle)
        #expect(noTime.segments.map(\.truncation) == [.first, .second])
    }

    @Test func aWorkingAgentIsActiveNow() {
        let metadata = LeoAgentMetadata(lastActiveAt: Self.now.addingTimeInterval(-3 * 3600), isWorking: true, task: nil)
        let presentation = LeoAgentRowPresentation(row: row("alpha", template: "claude", metadata: metadata), isSelected: false, now: Self.now)
        #expect(presentation.subtitle?.text == "claude · now")
    }

    @Test func timeAloneMakesASubtitle() {
        let metadata = LeoAgentMetadata(lastActiveAt: Self.now.addingTimeInterval(-7200), isWorking: false, task: nil)
        let presentation = LeoAgentRowPresentation(row: row("alpha", template: nil, metadata: metadata), isSelected: false, now: Self.now)
        #expect(presentation.subtitle?.text == "2h")
    }

    @Test func missingMetadataAddsNothing() {
        let presentation = LeoAgentRowPresentation(row: row("alpha", template: "claude"), isSelected: false, now: Self.now)
        #expect(presentation.subtitle?.text == "claude")
        #expect(presentation.subtitle?.lastActive == nil)
        #expect(presentation.task == nil)
        let bare = LeoAgentRowPresentation(row: row("alpha", template: nil), isSelected: false, now: Self.now)
        #expect(bare.subtitle == nil, "no placeholder")
    }

    @Test func noClockNoTime() {
        let metadata = LeoAgentMetadata(lastActiveAt: Self.now, isWorking: false, task: "Reading")
        let presentation = LeoAgentRowPresentation(row: row("alpha", template: "claude", metadata: metadata), isSelected: false)
        #expect(presentation.subtitle?.text == "claude")
        #expect(presentation.task == "Reading")
    }

    @Test func taskComesFromMetadataNotTheEventDrivenDetail() {
        let fromEvents = LeoAgentRow(host: .local, name: "alpha", template: nil, status: .running, activity: .working, actionDetail: "event detail")
        #expect(LeoAgentRowPresentation(row: fromEvents, isSelected: false, now: Self.now).task == nil)
        let metadata = LeoAgentMetadata(lastActiveAt: nil, isWorking: false, task: "snapshot task")
        #expect(LeoAgentRowPresentation(row: row("alpha", template: nil, metadata: metadata), isSelected: false, now: Self.now).task == "snapshot task")
    }

    // MARK: Helpers

    private static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func observed(
        _ name: String, startedAt: String?, lastActivityAt: String? = nil, detail: String? = nil, usage: LeoAgentUsage? = nil
    ) -> LeoObservedAgent {
        LeoObservedAgent(
            name: name, status: .running, activity: .idle, currentAction: detail.map { .init(kind: "pane", detail: $0) },
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
