import Foundation
import LeoKit

protocol LeoDaemonProbing: Sendable {
    func probe() async -> LeoDaemonProbeResult
    /// `/health` with the daemon's `pid` (B10).
    func health() async -> LeoDaemonHealthCheck
}

enum LeoDaemonHealthCheck: Equatable, Sendable {
    /// `pid` is nil from a daemon that predates the field.
    case answered(version: String, pid: Int32?)
    /// Nothing listens on the socket.
    case absent
    /// Something listens but gave no usable answer in time.
    case unresponsive
}

/// Asks the daemon on `~/.leo/state/leo.sock` who it is. The socket is
/// authoritative for "is a daemon running" (contract C13).
struct LeoDaemonProbe: LeoDaemonProbing {
    static let timeout: TimeInterval = 2

    let socketPath: String
    let transport: any LeoDaemonTransport

    func probe() async -> LeoDaemonProbeResult {
        switch await health() {
        case .answered(let version, _): .live(version: version)
        case .absent: .absent
        case .unresponsive: .unresponsive
        }
    }

    func health() async -> LeoDaemonHealthCheck {
        do {
            let response = try await transport.send(
                LeoHTTPRequest(method: "GET", path: "/health"), socketPath: socketPath, timeout: Self.timeout
            )
            guard (200..<300).contains(response.status),
                  let health = try? JSONDecoder().decode(Health.self, from: response.body),
                  health.ok, let data = health.data, !data.version.isEmpty else { return .unresponsive }
            return .answered(version: data.version, pid: data.pid)
        } catch LeoDaemonError.timeout {
            return .unresponsive
        } catch {
            // No socket, or a stale one nothing listens on.
            return .absent
        }
    }

    /// `claude` from `/health` (leo ≥ 0.56.2), re-resolved by the daemon on
    /// each call. Anything but a well-formed field is `.unreported`.
    func claudeHealth() async -> LeoClaudeHealth {
        guard let response = try? await transport.send(
            LeoHTTPRequest(method: "GET", path: "/health"), socketPath: socketPath, timeout: Self.timeout
        ), (200..<300).contains(response.status),
        let claude = try? JSONDecoder().decode(ClaudeEnvelope.self, from: response.body).data?.claude else { return .unreported }
        return claude.found ? .found(path: claude.path) : .missing
    }

    /// Lenient on its own: a malformed `claude` never turns a healthy answer into "unresponsive".
    private struct ClaudeEnvelope: Decodable {
        struct Claude: Decodable {
            let found: Bool
            let path: String?
        }
        struct Payload: Decodable {
            let claude: Claude?

            init(from decoder: any Decoder) throws {
                claude = try? decoder.container(keyedBy: CodingKeys.self).decode(Claude.self, forKey: .claude)
            }

            private enum CodingKeys: String, CodingKey { case claude }
        }
        let data: Payload?
    }

    /// `/health` carries the same bare-semver version as `hello`.
    private struct Health: Decodable {
        struct Payload: Decodable {
            let version: String
            /// This daemon boot's process (leo ≥ 0.56.0).
            let pid: Int32?
        }
        let ok: Bool
        let data: Payload?
    }
}
