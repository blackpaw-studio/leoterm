import LeoFeatures
import LeoKit
import UIKit

/// The app's agent browsers (B-305): one runtime over every paired daemon,
/// whose browsers are WebKit ones parked off the side of the app's window.
@MainActor enum AgentBrowserApp {
    /// Every browser's off-screen lot lives in the app's key window.
    static let parking = LeoIOSBrowserParking {
        UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    /// The runtime the live client-tools client drives. `makeClient`
    /// replaces the HTTPS client (fixtures).
    static func runtime(makeClient: ClientToolsRuntime.MakeClient? = nil) -> ClientToolsRuntime {
        let makeBrowser: ClientToolsRuntime.MakeBrowser = { key, machine in
            guard case .remote(let daemonID) = key.host else { return nil }
            return LeoIOSAgentBrowser(
                key: key, machineName: machine,
                configuration: LeoIOSAgentBrowser.configuration(daemonID: daemonID, agent: key.agent), viewHost: parking
            )
        }
        let runtime = makeClient.map { ClientToolsRuntime(makeBrowser: makeBrowser, makeClient: $0) } ?? ClientToolsRuntime(makeBrowser: makeBrowser)
        // Leaving the foreground withdraws every browser's pending
        // permission ask (D-894); dialogs stay for whoever answers (D-913).
        runtime.onForegroundChange = { [weak runtime] isForeground in
            guard !isForeground, let browsers = runtime?.browsers else { return }
            browsers.keys.compactMap { browsers.model(for: $0) as? LeoIOSAgentBrowser }.forEach { $0.paneHidden() }
        }
        return runtime
    }

    /// Keeps the app running while `work` answers in-flight calls on the
    /// way to the background; iOS ends it early only if time runs out.
    @Sendable static func holdingBackground(_ work: @escaping @Sendable () async -> Void) async {
        let task = BackgroundTask()
        task.begin()
        await work()
        task.end()
    }
}

/// One `beginBackgroundTask` assertion, ended exactly once.
@MainActor private final class BackgroundTask: Sendable {
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Agent browser suspend") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
