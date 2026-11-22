import AppIntents
import LeoFeatures
import LeoKit

/// "Tell an agent": sends one message to a Leo agent without opening the
/// app. The reply arrives as the normal chat push. Shared by the app and
/// the Controls extension; `perform` is expected to run in the app, which
/// registers `AgentMessagingClient` with `AppDependencyManager`.
struct SendMessageToAgent: AppIntent {
    static let title: LocalizedStringResource = "Tell an Agent"
    static let description = IntentDescription("Sends a message to a Leo agent. The reply arrives as a notification.")
    static let openAppWhenRun = false

    @Parameter(title: "Agent")
    var agent: AgentEntity?

    /// Optional so the prompt can name the agent ("What should I tell zeus?").
    @Parameter(title: "Message")
    var message: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Tell \(\.$agent) \(\.$message)")
    }

    @Dependency var messaging: AgentMessagingClient

    init() {}

    /// A Control or Shortcut configured with an agent: no "Which agent?" prompt.
    init(agent: AgentEntity?) {
        self.agent = agent
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let directory = await messaging.agents()
        let resolution = LeoAgentResolution.resolve(
            configured: agent?.target.pushTarget, available: directory.targets, machineCount: directory.machineCount
        )
        let target: LeoAgentTarget
        switch resolution {
        case .noMachines:
            #if !LEO_CONTROLS_EXTENSION
            // Opens Leo (after Siri says it; the
            // extension can't, and never runs `perform` anyway.
            try await continueInForeground(IntentDialog("Pair a machine in Leo first."), alwaysConfirm: false)
            #endif
            return .result(dialog: "Pair a machine in Leo first.")
        case .send(let found):
            target = found
        case .ask(let options, let unavailable):
            target = try await chooseAgent(among: options, unavailable: unavailable)
        }
        let text = try await resolvedMessage(for: target, among: directory.targets)
        let result = await messaging.send(target, text)
        return .result(dialog: IntentDialog(stringLiteral: Self.dialog(for: result.outcome)))
    }

    private func chooseAgent(among options: [LeoAgentTarget], unavailable: String?) async throws -> LeoAgentTarget {
        let entities = AgentEntity.entities(for: options)
        let prompt = unavailable.map { String(localized: "\($0) isn't available. Which agent?") } ?? String(localized: "Which agent?")
        let picked = try await $agent.requestDisambiguation(among: entities, dialog: IntentDialog(stringLiteral: prompt))
        return picked.target
    }

    private func resolvedMessage(for target: LeoAgentTarget, among all: [LeoAgentTarget]) async throws -> String {
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return message }
        let name = target.displayName(among: all)
        return try await $message.requestValue(IntentDialog(stringLiteral: String(localized: "What should I tell \(name)?")))
    }

    /// What Siri says; LeoKit names the outcome, the app words it.
    static func dialog(for outcome: LeoAgentSendOutcome) -> String {
        switch outcome {
        case .sent(let agent): String(localized: "Sent to \(agent).")
        case .unreachable(let machine): String(localized: "Couldn't reach \(machine).")
        case .agentMissing(let agent): String(localized: "\(agent) isn't available.")
        }
    }
}

#if !LEO_CONTROLS_EXTENSION
// `ForegroundContinuableIntent` isn't available in app extensions.
extension SendMessageToAgent: ForegroundContinuableIntent {}
#endif
