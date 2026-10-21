import Foundation
import LeoKit

protocol LeoDaemonProbing: Sendable {
    func probe() async -> LeoDaemonProbeResult
}

/// Asks the daemon on `~/.leo/state/leo.sock` who it is. The socket is
/// authoritative for "is a daemon running" (contract C13).
struct LeoDaemonProbe: LeoDaemonProbing {
    static let timeout: TimeInterval = 2

    let socketPath: String
    let transport: any LeoDaemonTransport

    func probe() async -> LeoDaemonProbeResult {
        do {
            let response = try await transport.send(
                LeoHTTPRequest(method: "GET", path: "/health"), socketPath: socketPath, timeout: Self.timeout
            )
            guard (200..<300).contains(response.status),
                  let health = try? JSONDecoder().decode(Health.self, from: response.body),
                  health.ok, let version = health.data?.version, !version.isEmpty else { return .unresponsive }
            return .live(version: version)
        } catch LeoDaemonError.timeout {
            return .unresponsive
        } catch {
            // No socket, or a stale one nothing listens on.
            return .absent
        }
    }

    /// `/health` carries the same bare-semver version as `hello`.
    private struct Health: Decodable {
        struct Payload: Decodable { let version: String }
        let ok: Bool
        let data: Payload?
    }
}
