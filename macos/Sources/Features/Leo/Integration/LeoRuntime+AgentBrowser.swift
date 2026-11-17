import AppKit
import LeoKit

/// The production agent browsers: WebKit browsers (macOS 14) driven through
/// the app's own event routing, each remote machine's port forwards on its
/// ssh connection, and a client-tools client on each machine's daemon socket.
///
/// A test host runs none of it: it talks to the user's real daemon, and
/// registering there would hand it real agents' browser calls.
extension LeoRuntime {
    /// `workspace` is the agent's workspace path as its daemon reports it
    /// (nil for a dispatch, which has none): where its downloads land.
    static func makeAgentBrowsers(
        machines: LeoMachineRegistry, defaults: UserDefaults, poster: any LeoNotificationPosting,
        notificationsEnabled: @escaping () -> Bool, displayName: @escaping (LeoAgentRow.ID) -> String? = { _ in nil },
        workspace: @escaping @MainActor (LeoAgentBrowserKey) -> String? = { _ in nil }
    ) -> LeoAgentBrowserRuntime {
        let forwards = LeoMachinePortForwards(makeForwards: { [weak machines] host in machines?.makePortForwards(for: host) })
        let isSupported = LeoAgentBrowserSetting.isPlatformSupported && !LeoSingleInstance.isRunningAsTestHost()
        return LeoAgentBrowserRuntime(
            setting: LeoAgentBrowserSetting(defaults: defaults, isSupported: isSupported), forwards: forwards,
            makeBrowser: makeWebKitBrowser(machines: machines, forwards: forwards, workspace: workspace),
            makeClient: { host, socketPath in
                let transport: any LeoSocketActivityTransport = host == .local
                    ? LeoUnixSocketTransport()
                    : LeoTunnelSocketTransport(base: LeoUnixSocketTransport())
                return LeoClientToolsClient(socketPath: socketPath, transport: transport)
            },
            poster: poster, notificationsEnabled: notificationsEnabled, displayName: displayName
        )
    }

    /// Nil before macOS 14, or when `NSApp` is not the Leo application.
    /// Sweeps what an earlier run left in the download staging folder.
    private static func makeWebKitBrowser(
        machines: LeoMachineRegistry, forwards: LeoMachinePortForwards, workspace: @escaping @MainActor (LeoAgentBrowserKey) -> String?
    ) -> LeoAgentBrowsers.MakeBrowser? {
        guard #available(macOS 14, *), let application = NSApp as? LeoApplication else { return nil }
        LeoWKBrowserDownloads.sweep()
        let factory = LeoAgentBrowserFactory(
            machineID: { [weak machines] host in browserMachineID(host, configuration: machines?.configuration(for: host)) },
            urlMapping: { key in forwards.mapping(for: key) },
            input: LeoSyntheticInput(application: application),
            viewHost: LeoAgentBrowserHost(),
            makeDownloads: { key in browserDownloads(for: key, machines: machines, workspace: workspace) }
        )
        return { factory.make($0) }
    }

    /// Downloads saved through `key`'s machine's file access (local or
    /// SFTP over its tunnel), into the agent's workspace as it is when each
    /// download finishes.
    static func browserDownloads(
        for key: LeoAgentBrowserKey, machines: LeoMachineRegistry, workspace: @escaping @MainActor (LeoAgentBrowserKey) -> String?
    ) -> LeoBrowserDownloads {
        let saver = LeoBrowserDownloadSaver(makeAccess: { [weak machines] in
            try await MainActor.run {
                guard let machines else { throw LeoFileAccessError.disconnected }
                return try machines.makeFileAccess(for: key.host)
            }
        })
        return LeoBrowserDownloads(saver: saver, workspace: { workspace(key) })
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
