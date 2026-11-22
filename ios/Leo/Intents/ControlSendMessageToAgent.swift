import AppIntents

/// What the Control runs. Apple runs a Control's intent in the widget
/// extension by default, and the extension has no `AgentMessagingClient`
/// and must never read the Keychain. So this intent sets `openAppWhenRun`:
/// the system launches Leo and runs it there, where it hands the chosen
/// agent and message to `SendMessageToAgent`. In the extension the body is
/// a stub that sends nothing; it only runs there if the system ignores
/// `openAppWhenRun`, and then it logs that and says so.
/// Compiled into both the app and `LeoControls`.
struct ControlSendMessageToAgent: AppIntent {
    static let title: LocalizedStringResource = "Tell an Agent"
    static let description = IntentDescription("Sends a message to a Leo agent from a Control.")
    static let openAppWhenRun = true
    /// Not a Shortcuts or Siri action: those use `SendMessageToAgent`.
    static let isDiscoverable = false

    @Parameter(title: "Agent")
    var agent: AgentEntity?

    @Parameter(title: "Message")
    var message: String?

    init() {}

    init(agent: AgentEntity?) {
        self.agent = agent
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentLog.performed("ControlSendMessageToAgent")
        #if LEO_CONTROLS_EXTENSION
        // No secrets and no sender here: nothing is sent from this process.
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "Open Leo to send your message.")))
        #else
        var intent = SendMessageToAgent(agent: agent)
        intent.message = message
        return try await intent.perform()
        #endif
    }
}
