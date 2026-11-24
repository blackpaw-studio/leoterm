import AppIntents
import Foundation
import LeoKit

extension LeoRuntime {
    /// The sender "Tell an agent" and Retry use: every enabled machine, and
    /// each connected machine's Leo Chat client. Read through the runtime on
    /// every call, so a machine that connects later is picked up.
    func makeAgentMessageSender() -> LeoAgentMessageSender {
        LeoAgentMessageSender(
            machines: { [weak self] in
                let hosts = await MainActor.run { self?.agentMessagingHosts() ?? [] }
                return LeoAgentMachine.machines(hosts: hosts) { host in await MainActor.run { self?.clients.daemon(for: host) } }
            },
            chat: { [weak self] machineID in
                let client: (any LeoChatClient)? = await MainActor.run {
                    guard let host = LeoAgentMachineID.host(for: machineID) else { return nil }
                    return self?.chat.client(for: host)
                }
                guard let client else { throw LeoAgentMachineUnavailable(host: LeoAgentMachineID.host(for: machineID) ?? .local) }
                return client
            }
        )
    }

    /// Registers the sender for App Intents. Called once, from `AppDelegate.init`.
    func registerAgentMessaging() {
        let sender = makeAgentMessageSender()
        AppDependencyManager.shared.add(dependency: sender)
    }

    /// Enabled machines, This Mac first.
    private func agentMessagingHosts() -> [LeoHostID] {
        machines.machines.filter { $0 == .local || machines.configuration(for: $0)?.isEnabled != false }
    }
}
