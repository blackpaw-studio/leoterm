#if DEBUG
import Foundation
import OSLog

/// DEBUG builds only: overlays attention states onto the local daemon's
/// `/state` from a JSON file named by `LEO_ATTENTION_FIXTURE`
/// (`{"alpha": {"state": "needs_input", "revision": 1}, ...}`), so the
/// badges can be seen and screenshotted before the daemon emits
/// `attention` itself. Only named agents change; nothing is sent anywhere.
enum LeoAttentionFixture {
    static let environmentKey = "LEO_ATTENTION_FIXTURE"
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: LeoAttentionSignal]? {
        guard let path = environment[environmentKey] else { return nil }
        do {
            return try JSONDecoder().decode([String: LeoAttentionSignal].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            logger.error("attention fixture \(path, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func wrap(_ source: LeoSidebarActivitySource, overlay: [String: LeoAttentionSignal]) -> LeoSidebarActivitySource {
        LeoSidebarActivitySource(events: source.events, observedState: {
            let state = try await source.fetchState()
            let agents = state.agents.map { agent in
                guard let signal = overlay[agent.name] else { return agent }
                return LeoObservedAgent(
                    name: agent.name, host: agent.host, status: agent.status, activity: agent.activity,
                    currentAction: agent.currentAction, lastActivityAt: agent.lastActivityAt, attention: signal,
                    startedAt: agent.startedAt, surfacedFiles: agent.surfacedFiles, surfacedFilesSent: agent.surfacedFilesSent
                )
            }
            return LeoObservedState(agents: agents, dispatches: state.dispatches)
        })
    }
}
#endif
