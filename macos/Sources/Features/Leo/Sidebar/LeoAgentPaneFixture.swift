#if DEBUG
import Combine
import Foundation
import LeoKit

/// DEBUG builds only: `LEO_AGENT_PANE_FIXTURE=a|b|c|n` fills This Mac's sidebar
/// with three agents named `pane-fixture-*` and selects one, so the agent pane
/// can be screenshotted with no daemon: `a` has the full usage payload
/// (model, effort, context breakdown, rate limits, git), `b` only today's
/// fields, `c` none, `d` none from a harness that reports no usage, `n` the same rows with nothing selected. The names are not real agents; nothing attaches to them.
enum LeoAgentPaneFixture {
    static let environmentKey = "LEO_AGENT_PANE_FIXTURE"
    private static let generation = Int.max / 4

    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey].map { ["a", "b", "c", "d", "n"].contains($0) } ?? false
    }

    @MainActor static func arm(model: LeoSidebarModel, environment: [String: String] = ProcessInfo.processInfo.environment) -> AnyObject {
        Arming(model: model, selecting: environment[environmentKey] ?? "a")
    }

    @MainActor private final class Arming {
        private var subscription: AnyCancellable?

        init(model: LeoSidebarModel, selecting: String) {
            // `@Published` emits before it stores: hop, then read the model.
            subscription = model.$snapshots
                .receive(on: DispatchQueue.main)
                .sink { [weak model] _ in
                    guard let model, model.snapshot(for: .local) != nil,
                          model.snapshot(for: .local)?.rows.contains(where: { $0.name == "pane-fixture-a" }) != true else { return }
                    LeoAgentPaneFixture.fill(model, selecting: selecting)
                }
        }
    }

    @MainActor static func fill(_ model: LeoSidebarModel, selecting letter: String) {
        let rows = [
            row("pane-fixture-a", usage: Self.fullUsage, model: "claude-opus-5-5"),
            row("pane-fixture-b", usage: Self.todaysUsage, model: "claude-sonnet-5-5"),
            row("pane-fixture-c", usage: nil, model: nil),
            row("pane-fixture-d", usage: nil, model: nil, harness: "gemini"),
        ]
        model.receive(
            LeoSidebarSnapshot(
                rows: rows, connectivity: .connected, generation: generation, listRefreshSucceeded: true,
                attentionCount: 0, features: LeoDaemonFeatures(["agent_usage"]), featuresHost: .local),
            for: .local)
        model.selection = rows.first { $0.name == "pane-fixture-\(letter)" }?.id
    }

    private static func row(_ name: String, usage: LeoAgentUsage?, model: String?, harness: String = "claude") -> LeoAgentRow {
        LeoAgentRow(
            host: .local, name: name, template: "claude", status: .running, activity: .idle, actionDetail: nil,
            workspace: NSHomeDirectory() + "/.leo/agents/leoterm", repo: "blackpaw-studio/leoterm", branch: "feat/agent-bottom-pane",
            startedAt: "s", metadata: usage.map { LeoAgentMetadata(lastActiveAt: nil, isWorking: false, task: nil, usage: $0) },
            harness: harness, model: model)
    }

    private static func decode(_ json: String) -> LeoAgentUsage? { try? JSONDecoder().decode(LeoAgentUsage.self, from: Data(json.utf8)) }

    /// Today's daemon payload: session totals and context, nothing else.
    private static let todaysUsage = decode(#"""
    {"session_id":"s2","session":{"tokens":48200,"cost_usd":0.42},"context":{"tokens":48200,"window":200000,"percent":24}}
    """#)

    /// Everything the telemetry request asks the daemon for.
    /// The limits reset relative to launch, so the countdowns read like a live session's
    /// (2d 4h and 4d 2h), and the context holds 1.2k tokens no category accounts for.
    private static var fullUsage: LeoAgentUsage? {
        let hour: TimeInterval = 3600
        let formatter = ISO8601DateFormatter()
        let session = formatter.string(from: Date(timeIntervalSinceNow: 52 * hour + 60))
        let weekly = formatter.string(from: Date(timeIntervalSinceNow: 98 * hour + 60))
        return decode("""
        {"session_id":"s1","session":{"tokens":1250000,"cost_usd":12.8},"model":"claude-opus-5-5","effort":"high",
         "context":{"tokens":155200,"window":200000,"percent":77,"compact_at":0.9,
           "breakdown":{"system":3000,"tools":12000,"mcp":500,"memory":1500,"messages":137000}},
         "rate_limits":[{"kind":"five_hour","percent_used":42.5,"resets_at":"\(session)"},
                        {"kind":"seven_day","percent_used":10,"resets_at":"\(weekly)"}],
         "git":{"added":120,"removed":7}}
        """)
    }
}
#endif
