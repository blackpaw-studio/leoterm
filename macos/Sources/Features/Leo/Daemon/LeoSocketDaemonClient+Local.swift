import Foundation
import LeoKit

/// This Mac's daemon endpoint: the one place that decides which socket
/// "local" means. A hosted XCTest run (B-322) gets a socket that can never
/// exist and no legacy web config, so the suite cannot reach, or post to,
/// the production daemon.
enum LeoLocalDaemon {
    struct Endpoint: Equatable {
        let socketPath: String
        /// Whether `~/.leo/leo.yaml` and `api.token` may be read to reach the
        /// pre-socket web API.
        let readsLegacyWebConfig: Bool
    }

    private static let productionSocketPath = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath
    /// `/dev/null` is a file, so nothing can be created or connected below it.
    private static let testHostSocketPath = "/dev/null/leo-test-host.sock"

    static func resolve(isTestHost: Bool) -> Endpoint {
        isTestHost
            ? Endpoint(socketPath: testHostSocketPath, readsLegacyWebConfig: false)
            : Endpoint(socketPath: productionSocketPath, readsLegacyWebConfig: true)
    }

    static let current = resolve(isTestHost: LeoSingleInstance.isRunningAsTestHost())

    static var socketPath: String { current.socketPath }

    /// The legacy web API's address and token, or nil where there is none to
    /// read (a test host).
    static func observeConfig() -> LeoObserveConfig? {
        current.readsLegacyWebConfig ? LeoObserveConfigLoader.load() : nil
    }
}

extension LeoSocketDaemonClient {
    init(socketPath: String = LeoLocalDaemon.socketPath, defaultTimeout: TimeInterval = 5, mutationTimeout: TimeInterval = 30) {
        self.init(socketPath: socketPath, defaultTimeout: defaultTimeout, mutationTimeout: mutationTimeout, transport: LeoUnixSocketTransport())
    }

    static func detectFlavor(socketPath: String = LeoLocalDaemon.socketPath) async -> LeoAPIFlavor {
        await detectFlavor(socketPath: socketPath, transport: LeoUnixSocketTransport())
    }
}

extension LeoSocketActivityClient {
    init(socketPath: String = LeoLocalDaemon.socketPath) {
        self.init(socketPath: socketPath, transport: LeoUnixSocketTransport())
    }
}
