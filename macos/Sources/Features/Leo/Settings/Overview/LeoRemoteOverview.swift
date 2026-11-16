import Foundation
import LeoKit

/// What Settings ▸ a remote machine shows above its connection form.
struct LeoRemoteOverview: Equatable {
    let name: String
    let subtitle: String
    let isEnabled: Bool
    /// The badge: off when the draft says so, else the live connection.
    let status: LeoMachineStatus?
    /// Why the machine can't be used: that it is turned off, the connection error, or that it needs saving.
    let reason: String?
    /// The daemon's version; only known while this machine is the one Settings is connected to.
    let version: String?
    /// Known to the app. An unsaved machine can't open its panes yet.
    let isSaved: Bool

    init(host: LeoHostConfiguration, status: LeoMachineStatus?, isTarget: Bool, daemonVersion: String?, isSaved: Bool = true) {
        self.isSaved = isSaved
        name = host.name.isEmpty ? "Untitled" : host.name
        subtitle = host.sshTarget.isEmpty ? "Remote over SSH" : "Remote over SSH · \(host.sshTarget)"
        isEnabled = host.isEnabled
        self.status = host.isEnabled ? status : .disabled
        switch (host.isEnabled, status) {
        case (false, _): reason = "Turned off. Turn on Enabled to connect and edit its settings."
        case (true, .failed(let message)?): reason = message
        case (true, _): reason = isSaved ? nil : "Save this machine to edit its settings"
        }
        version = isTarget && host.isEnabled ? daemonVersion : nil
    }
}
