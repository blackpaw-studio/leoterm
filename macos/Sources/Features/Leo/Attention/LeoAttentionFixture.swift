#if DEBUG
import Foundation
import OSLog

/// DEBUG builds only: overlays attention states onto the local daemon's
/// `/state` from a JSON file named by `LEO_ATTENTION_FIXTURE`
/// (`{"alpha": {"state": "needs_input", "revision": 1}, ...}`), so the
/// badges can be seen and screenshotted before the daemon emits
/// `attention` itself. A reserved `"dispatches"` key holds an array of
/// dispatch records added to `/state` (B-257), so nested dispatch rows can
/// be screenshotted too. Only named agents change; nothing is sent anywhere.
enum LeoAttentionFixture {
    static let environmentKey = "LEO_ATTENTION_FIXTURE"
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    /// The whole fixture file: attention by agent name, plus dispatches.
    struct File: Decodable, Equatable {
        static let dispatchesKey = "dispatches"

        let attention: [String: LeoAttentionSignal]
        let dispatches: [LeoDispatch]

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue _: Int) { nil }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            var attention: [String: LeoAttentionSignal] = [:]
            var dispatches: [LeoDispatch] = []
            for key in container.allKeys {
                if key.stringValue == Self.dispatchesKey {
                    dispatches = try container.decode(LeoLenientDispatches.self, forKey: key).dispatches
                } else {
                    attention[key.stringValue] = try container.decode(LeoAttentionSignal.self, forKey: key)
                }
            }
            self.attention = attention
            self.dispatches = dispatches.sorted { ($0.startedAt ?? "", $0.id) < ($1.startedAt ?? "", $1.id) }
        }
    }

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: LeoAttentionSignal]? {
        loadFile(environment: environment)?.attention
    }

    static func loadFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> File? {
        guard let path = environment[environmentKey] else { return nil }
        do {
            return try JSONDecoder().decode(File.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            logger.error("attention fixture \(path, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func wrap(_ source: LeoSidebarActivitySource, overlay: [String: LeoAttentionSignal], dispatches: [LeoDispatch] = []) -> LeoSidebarActivitySource {
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
            let fixtureIDs = Set(dispatches.map(\.id))
            return LeoObservedState(agents: agents, dispatches: state.dispatches.filter { !fixtureIDs.contains($0.id) } + dispatches)
        })
    }
}
#endif
