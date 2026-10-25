import LeoKit
import SwiftUI

/// What the app can do about a pending restart. An action is nil until
/// the machine's service API is wired, and its button is then left out. An
/// action answers why it failed, or nil when it went through.
struct LeoConfigRestartActions {
    var restartService: (() async -> String?)?
    var restartAgents: (() async -> String?)?
    /// How many agents are running now, read when Restart All Agents is chosen.
    var runningAgents: (() async -> Int?)?

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
    @State private var isWorking = false
    @State private var failure: String?
    /// The running-agent count the Restart All Agents question names.
    @State private var runningAgents: Int?

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
                if let failure {
                    Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            if required.service, actions.restartService != nil {
                Button("Restart Daemon") { confirming = .service }.disabled(isWorking)
            }
            if required.agents, actions.restartAgents != nil {
                Button("Restart All Agents") { Task { await askAboutAgents() } }.disabled(isWorking)
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
                Task { await run(kind) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { kind in
            Text(kind == .service
                ? "Running agents keep their tmux sessions."
                : LeoServiceText.agentsRestartMessage(running: runningAgents))
        }
    }

    /// Reads how many agents are running, then asks: the answer names the count.
    private func askAboutAgents() async {
        runningAgents = await actions.runningAgents?()
        confirming = .agents
    }

    /// Runs the confirmed restart. The prompt goes away when it went through
    /// and stays, with the reason, when it didn't. `kind` is the one the dialog
    /// showed: the dialog has cleared `confirming` by the time its button runs.
    private func run(_ kind: Kind) async {
        isWorking = true
        failure = nil
        defer { isWorking = false }
        let action = kind == .service ? actions.restartService : actions.restartAgents
        if let message = await action?() {
            failure = message
        } else {
            dismiss()
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
