import AppIntents
import SwiftUI
import WidgetKit

/// The agent a Control is configured with. Optional: with none, the intent
/// asks "Which agent?" when it runs.
struct SendToAgentConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Tell an Agent"

    @Parameter(title: "Agent")
    var agent: AgentEntity?
}

/// A Control for the Action button, Control Center or the Lock Screen:
/// press, speak, and the message goes to the agent. It holds no secrets;
/// its intent opens Leo, which sends.
struct SendToAgentControl: ControlWidget {
    static let kind = "studio.blackpaw.leo.ios.controls.send-to-agent"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, provider: Provider()) { agent in
            ControlWidgetButton(action: ControlSendMessageToAgent(agent: agent)) {
                Label(agent?.name ?? String(localized: "Tell an Agent"), systemImage: "waveform")
            }
        }
        .displayName("Tell an Agent")
        .description("Speak a message to a Leo agent.")
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: SendToAgentConfiguration) -> AgentEntity? {
            configuration.agent
        }

        func currentValue(configuration: SendToAgentConfiguration) async throws -> AgentEntity? {
            configuration.agent
        }
    }
}

@main
struct LeoControlsBundle: WidgetBundle {
    var body: some Widget {
        SendToAgentControl()
    }
}
