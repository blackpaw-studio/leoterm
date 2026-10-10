import Foundation
import Testing

@testable import Ghostty

/// B-283 on the row: an override's names show quietly (the fallback line
/// and the tooltip); the default source shows nothing; a config problem is
/// a plain warning line. No badge, no motion, never a value.
struct LeoAgentRowEnvironmentsPresentationTests {
    private func presentation(_ environments: LeoAgentEnvironments?, task: String? = nil, error: String? = nil) -> LeoAgentRowPresentation {
        let metadata = task.map { LeoAgentMetadata(lastActiveAt: nil, isWorking: false, task: $0, usage: nil, tool: nil) }
        let row = LeoAgentRow(
            host: .local, name: "alpha", template: "claude", status: .running, activity: .idle, actionDetail: nil,
            metadata: metadata, environments: environments
        )
        return LeoAgentRowPresentation(row: row, error: error)
    }

    @Test func overrideNamesInSubtitleAndTooltip() {
        let shown = presentation(LeoAgentEnvironments(names: ["aws", "prod"], source: .override, error: nil))
        #expect(shown.detail == .fallback("claude · env: aws, prod"))
        #expect(shown.help == "claude\nEnvironments: aws, prod")
        #expect(shown.pill == presentation(nil).pill)
    }

    @Test func defaultSourceShowsNothing() {
        let fallback = presentation(LeoAgentEnvironments(names: ["aws"], source: .default, error: nil))
        #expect(fallback.detail == .fallback("claude"))
        #expect(fallback.help == "claude")
        #expect(presentation(LeoAgentEnvironments(names: [], source: .override, error: nil)).detail == .fallback("claude"))
    }

    @Test func environmentErrorIsPlainWarning() {
        let broken = LeoAgentEnvironments(names: ["gone"], source: .override, error: "environment \"gone\" is not configured")
        #expect(presentation(broken).detail == .warning("environment \"gone\" is not configured"))
        #expect(presentation(broken, task: "Reading").detail == .warning("environment \"gone\" is not configured"))
        #expect(presentation(broken, error: "boom").detail == .error("boom"))
        #expect(presentation(LeoAgentEnvironments(names: [], source: .default, error: "x")).detail == .warning("x"))
    }
}
