import AppIntents
import AppKit
import LeoKit

/// "Tell an agent": sends one message to an agent on a paired machine.
@available(macOS 15.0, *)
struct SendMessageToLeoAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "Tell an Agent"
    static var description = IntentDescription("Send a message to a Leo agent.")

    @Parameter(title: "Agent", description: "The agent to tell. Asked when left empty.")
    var agent: LeoAgentEntity?

    @Parameter(
        title: "Message", description: "What to tell the agent.",
        requestValueDialog: IntentDialog("What should I tell the agent?"))
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Tell \(\.$agent) \(\.$message)")
    }

    @Dependency var sender: LeoAgentMessageSender

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await run())
    }

    @MainActor
    private func run() async throws -> IntentDialog {
        let directory = await sender.agents()
        let configured = agent?.parts.map { LeoPushTarget(daemonID: $0.machineID, agent: $0.agent) }
        let resolution = LeoAgentResolution.resolve(
            configured: configured, available: directory.targets, machineCount: directory.machineCount)

        switch resolution {
        case .noMachines:
            NSApp.activate(ignoringOtherApps: true)
            return "Pair a machine in Leo first"
        case .send(let target):
            return await deliver(message, to: target)
        case .ask(let options, let unavailable):
            guard !options.isEmpty else { return "Couldn't reach any machine." }
            let entities = options.map { LeoAgentEntity(target: $0, among: options) }
            let prompt: IntentDialog = unavailable.map { "\($0) isn't available. Which agent?" } ?? "Which agent?"
            let chosen = try await $agent.requestDisambiguation(among: entities, dialog: prompt)
            guard let target = chosen.target(in: directory) else { return "\(chosen.label) isn't available." }
            return await deliver(message, to: target)
        }
    }

    private func deliver(_ text: String, to target: LeoAgentTarget) async -> IntentDialog {
        let result = await sender.send(target, text: text)
        if let payload = result.retryPayload {
            await LeoSendFailedRetry.postToNotificationCenter(LeoChatNotificationActions.sendFailedContent(payload))
        }
        return Self.dialog(for: result.outcome)
    }

    static func dialog(for outcome: LeoAgentSendOutcome) -> IntentDialog {
        switch outcome {
        case .sent(let agent): "Sent to \(agent)."
        case .unreachable(let machine): "Couldn't reach \(machine)."
        case .agentMissing(let agent): "\(agent) isn't available."
        }
    }
}
