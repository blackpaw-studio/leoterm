import Foundation
import LeoKit

/// How the Mac names a machine to LeoKit's agent messaging: `LeoHostID`
/// round-trips through a string id, so a Retry notification can find its
/// machine again.
enum LeoAgentMachineID {
    private static let remotePrefix = "remote:"
    private static let local = "local"

    static func id(for host: LeoHostID) -> String {
        switch host {
        case .local: local
        case .remote(let name): remotePrefix + name
        }
    }

    static func host(for id: String) -> LeoHostID? {
        if id == local { return .local }
        guard id.hasPrefix(remotePrefix) else { return nil }
        let name = String(id.dropFirst(remotePrefix.count))
        return name.isEmpty ? nil : .remote(name)
    }

    static func name(for host: LeoHostID) -> String {
        host == .local ? "This Mac" : host.displayName
    }
}

extension LeoAgentMachine {
    /// One machine per host. A host with no daemon client (not connected)
    /// throws when asked for agents, so it counts as paired but unreachable.
    static func machines(
        hosts: [LeoHostID], daemon: @escaping @Sendable (LeoHostID) async -> (any LeoDaemonClient)?
    ) -> [LeoAgentMachine] {
        hosts.map { host in
            LeoAgentMachine(id: LeoAgentMachineID.id(for: host), name: LeoAgentMachineID.name(for: host)) {
                guard let client = await daemon(host) else { throw LeoAgentMachineUnavailable(host: host) }
                return try await client.listAgents().map(\.name)
            }
        }
    }
}

struct LeoAgentMachineUnavailable: Error, Equatable {
    let host: LeoHostID
}
