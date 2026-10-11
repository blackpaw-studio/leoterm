import Foundation
import LeoKit

/// The local daemon's socket, and the unix-socket transport LeoKit's
/// clients default to on the Mac.
enum LeoLocalDaemon {
    static let socketPath = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath
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
