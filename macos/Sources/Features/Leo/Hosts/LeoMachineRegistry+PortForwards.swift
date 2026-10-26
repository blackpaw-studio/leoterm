import Foundation
import LeoKit

extension LeoMachineRegistry {
    /// `host`'s port forwards for agent browsers on the connection that
    /// just came up: over its ControlMaster when one is live, one ssh
    /// process each otherwise. Nil for This Mac, or a machine that is no
    /// longer configured.
    func makePortForwards(for host: LeoHostID, prober: any LeoPortProbing = LeoLoopbackPortProber()) -> LeoPortForwards? {
        guard case .remote = host, let configuration = configuration(for: host), configuration.isEnabled else { return nil }
        let environment = environment
        let command = LeoSSHCommand(configuration: configuration)
        let path = environment.controlPath(for: configuration)
        let hasLiveControlSocket = LeoSSHCommand.isValidControlPath(path)
            && LeoControlSocket.inspect(path, owner: environment.controlSocketOwner) == .live
        return LeoPortForwards(
            planner: LeoPortForwardPlanner(isRemote: true, prober: prober),
            controlPath: hasLiveControlSocket ? path : nil,
            makeMux: { controlPath in
                LeoMuxForwardRunner(
                    command: command, controlPath: controlPath, runner: environment.runner,
                    sshExecutable: environment.sshExecutable, prober: prober
                )
            },
            makeProcess: {
                LeoProcessForwardRunner(
                    host: host, command: command, sshExecutable: environment.sshExecutable, prober: prober,
                    makeTunnel: environment.makeTunnel
                )
            }
        )
    }
}
