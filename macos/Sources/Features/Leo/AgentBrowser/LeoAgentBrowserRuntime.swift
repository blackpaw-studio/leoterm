import Combine
import Foundation
import LeoKit

/// The app's agent browsers wired to its machines: the registry, each
/// connected machine's client-tools session and port forwards, the handoff
/// notifier, and the Agent browser setting over all of them.
///
/// A machine's session and forwards follow its connection; its browsers
/// outlive a reconnect and close when its listing no longer has their
/// agent. Turning the setting off closes every session's stream and every
/// browser (their stores stay).
@MainActor final class LeoAgentBrowserRuntime {
    /// A client-tools client for a machine's daemon socket.
    typealias MakeClient = @MainActor (_ host: LeoHostID, _ socketPath: String) -> any LeoClientToolsProviding

    let browsers: LeoAgentBrowsers
    let setting: LeoAgentBrowserSetting
    private let forwards: LeoMachinePortForwards
    private let makeClient: MakeClient
    private let handoff: LeoHandoffNotifier
    private var sessions: [LeoHostID: LeoClientToolsSession] = [:]
    /// Whether each machine's daemon last said it has `client_tools`.
    private var advertised: [LeoHostID: Bool] = [:]
    private var settingSubscription: AnyCancellable?

    /// `makeBrowser` is nil before macOS 14.
    init(
        setting: LeoAgentBrowserSetting, forwards: LeoMachinePortForwards, makeBrowser: LeoAgentBrowsers.MakeBrowser?,
        makeClient: @escaping MakeClient, poster: any LeoNotificationPosting, notificationsEnabled: @escaping () -> Bool
    ) {
        self.setting = setting
        self.forwards = forwards
        self.makeClient = makeClient
        let browsers = LeoAgentBrowsers(
            makeBrowser: { [setting] key in setting.isEnabled ? makeBrowser?(key) : nil },
            onClosed: { [weak forwards] key in Task { await forwards?.release(key) } }
        )
        self.browsers = browsers
        handoff = LeoHandoffNotifier(presence: browsers, poster: poster, isEnabled: notificationsEnabled)
        // `@Published` sends before it stores: the sink reads the sent value.
        settingSubscription = setting.$isOn.dropFirst().removeDuplicates()
            .sink { [weak self] isOn in MainActor.assumeIsolated { self?.settingChanged(isOn: isOn) } }
    }

    // MARK: - Machines

    /// `host`'s daemon is up at `socketPath`: its forwards ride this
    /// connection, and a fresh session serves its client tools.
    func machineConnected(_ host: LeoHostID, socketPath: String) {
        forwards.connected(host)
        sessions.removeValue(forKey: host)?.stop()
        let session = LeoClientToolsSession(
            host: host, client: makeClient(host, socketPath), executor: browsers, isPlatformSupported: setting.isSupported
        )
        session.setEnabled(setting.isEnabled)
        session.setAdvertised(advertised[host] ?? false)
        session.start()
        sessions[host] = session
    }

    /// `host` is connecting again, failed or went: its session stops and
    /// its forwards close. Its browsers stay until its listing drops them.
    func machineDisconnected(_ host: LeoHostID) {
        sessions.removeValue(forKey: host)?.stop()
        forwards.disconnected(host)
    }

    /// `host`'s sidebar snapshot: what its daemon advertises, and, from a
    /// list fetched while connected, which agents are gone.
    func snapshotLanded(_ snapshot: LeoSidebarSnapshot, for host: LeoHostID) {
        guard snapshot.connectivity == .connected else { return }
        let features = snapshot.advertised.applying(to: host)
        let hasClientTools = features.contains(.clientTools)
        if advertised[host] != hasClientTools {
            advertised[host] = hasClientTools
            sessions[host]?.setAdvertised(hasClientTools)
        }
        guard snapshot.listRefreshSucceeded else { return }
        let statuses = Dictionary(snapshot.rows.map { ($0.name, $0.status) }, uniquingKeysWith: { first, _ in first })
        let dispatches = features.contains(.dispatchTree)
            ? Set(snapshot.dispatchChildren.values.flatMap { $0.map(\.id) })
            : nil
        browsers.agentsListed(on: host, statuses: statuses, dispatches: dispatches)
    }

    /// The app is quitting: every stream stops, and every machine's
    /// forwards close in the returned task, which the quit waits on with the
    /// machines' own teardown (it needs no main actor).
    @discardableResult
    func shutdown() -> Task<Void, Never> {
        sessions.values.forEach { $0.stop() }
        sessions = [:]
        return forwards.shutdown()
    }

    // MARK: - Setting

    private func settingChanged(isOn: Bool) {
        let isEnabled = setting.isSupported && isOn
        sessions.values.forEach { $0.setEnabled(isEnabled) }
        guard !isEnabled else { return }
        browsers.keys.forEach(browsers.closeBrowser)
    }
}
