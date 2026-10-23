import LeoKit
import SwiftUI

/// What the app can do about a pending restart. An action is nil until
/// the machine's service API is wired, and its button is then left out.
struct LeoConfigRestartActions {
    var restartService: (() async -> Void)?
    var restartAgents: (() async -> Void)?

    static let none = LeoConfigRestartActions()
}

/// "Restart needed" after a save the running daemon or agents don't pick up
/// on their own. Each restart confirms first and names the machine.
struct LeoRestartPrompt: View {
    let required: LeoConfigRestartRequired
    let machine: String
    let actions: LeoConfigRestartActions
    let dismiss: () -> Void

    @State private var confirming: Kind?

    private enum Kind: Identifiable {
        case service, agents
        var id: Self { self }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.headline)
                Text("Saved to leo.yaml on \(machine). Running processes keep the old settings until then.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if required.service, actions.restartService != nil {
                Button("Restart Daemon") { confirming = .service }
            }
            if required.agents, actions.restartAgents != nil {
                Button("Restart All Agents") { confirming = .agents }
            }
            Button("Later", action: dismiss)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .confirmationDialog(
            confirming == .service ? "Restart leo on \(machine)?" : "Restart every agent on \(machine)?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming
        ) { kind in
            Button(kind == .service ? "Restart Daemon" : "Restart All Agents", role: .destructive) {
                Task { await (kind == .service ? actions.restartService : actions.restartAgents)?() }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: { kind in
            Text(kind == .service
                ? "Running agents keep their tmux sessions."
                : "Each agent is restarted and loses its current turn.")
        }
    }

    private var headline: String {
        switch (required.service, required.agents) {
        case (true, true): "Restart the daemon and agents to apply this"
        case (true, false): "Restart the daemon to apply this"
        default: "Restart agents to apply this"
        }
    }
}
