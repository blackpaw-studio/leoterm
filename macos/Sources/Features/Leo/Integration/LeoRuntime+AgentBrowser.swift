import AppKit
import LeoKit

/// The production agent browsers: WebKit browsers (macOS 14) driven through
/// the app's own event routing, each remote machine's port forwards on its
/// ssh connection, and a client-tools client on each machine's daemon socket.
extension LeoRuntime {
    static func makeAgentBrowsers(
        machines: LeoMachineRegistry, defaults: UserDefaults, poster: any LeoNotificationPosting,
        notificationsEnabled: @escaping () -> Bool
    ) -> LeoAgentBrowserRuntime {
        let forwards = LeoMachinePortForwards(makeForwards: { [weak machines] host in machines?.makePortForwards(for: host) })
        return LeoAgentBrowserRuntime(
            setting: LeoAgentBrowserSetting(defaults: defaults), forwards: forwards,
            makeBrowser: makeWebKitBrowser(machines: machines, forwards: forwards),
            makeClient: { host, socketPath in
                let transport: any LeoSocketActivityTransport = host == .local
                    ? LeoUnixSocketTransport()
                    : LeoTunnelSocketTransport(base: LeoUnixSocketTransport())
                return LeoClientToolsClient(socketPath: socketPath, transport: transport)
            },
            poster: poster, notificationsEnabled: notificationsEnabled
        )
    }

    /// Nil before macOS 14, or outside the app (a test host).
    private static func makeWebKitBrowser(machines: LeoMachineRegistry, forwards: LeoMachinePortForwards) -> LeoAgentBrowsers.MakeBrowser? {
        guard #available(macOS 14, *), let application = NSApp as? LeoApplication else { return nil }
        let factory = LeoAgentBrowserFactory(
            machineID: { [weak machines] host in browserMachineID(host, configuration: machines?.configuration(for: host)) },
            urlMapping: { key in forwards.mapping(for: key) },
            input: LeoSyntheticInput(application: application),
            viewHost: LeoAgentBrowserHost()
        )
        return { factory.make($0) }
    }

    /// The machine part of an agent's data store name: stable across
    /// renames of a remote machine, fresh for one removed and added again.
    static func browserMachineID(_ host: LeoHostID, configuration: LeoHostConfiguration?) -> String {
        switch host {
        case .local: "local"
        case .remote(let name): configuration?.id.uuidString ?? name
        }
    }
}
