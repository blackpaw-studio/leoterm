import Foundation

/// How a plugin's fetch reaches another machine's daemon: the live client for
/// a machine, or nil while it has none (connecting, failed, disabled, unknown).
public protocol LeoPluginRemoteCredentialForwarding: Sendable {
    @MainActor func daemon(for host: LeoHostID) -> (any LeoDaemonClient)?
}

/// Acts as one account on another machine. The daemon there reads the token
/// and makes the request; this side only forwards what already passed the
/// plugin's checks, and words every failure the way local fetches do.
struct LeoPluginRemoteCredentialFetcher: Sendable {
    let host: LeoHostID
    let kind: LeoPluginCredentialKind
    let dir: String
    let forwarding: (any LeoPluginRemoteCredentialForwarding)?

    private var machine: String { host.displayName }

    func forward(_ request: LeoPluginRemoteFetchRequest) async throws -> LeoPluginFetchResponse {
        let client = try await liveClient()
        let wire = LeoCredentialFetchRequest(
            kind: kind, dir: dir, url: request.url, method: request.method, headers: request.headers, body: request.body)
        do {
            return try Self.response(from: try await client.credentialFetch(wire))
        } catch {
            throw mapped(error)
        }
    }

    /// Whether the machine's daemon will act as this account (`/credentials/check`).
    func check() async throws {
        let client = try await liveClient()
        do {
            try await client.credentialCheck(kind: kind, dir: dir)
        } catch {
            throw mapped(error)
        }
    }

    private func liveClient() async throws -> any LeoDaemonClient {
        guard let forwarding, let client = await forwarding.daemon(for: host) else {
            throw LeoPluginFetchError.credentialMachineUnavailable("\(machine) is offline")
        }
        return client
    }

    private func mapped(_ error: any Error) -> any Error {
        switch error {
        case let remote as LeoCredentialRemoteError: Self.map(remote)
        case let daemon as LeoDaemonError: map(daemon)
        default: error
        }
    }

    private static func map(_ error: LeoCredentialRemoteError) -> LeoPluginFetchError {
        switch error.reason {
        case "invalidRequest": .invalidRequest(error.message)
        case "bodyTooLarge": .bodyTooLarge(limit: LeoPluginFetcher.maxBodyBytes)
        case "networkError": .network(error.message)
        case "credentialHostMismatch", "credentialHeaderConflict", "credentialNeedsAuthorization", "credentialInvalid":
            .credentialRemote(code: error.reason, message: error.message)
        default: .network("unexpected reply: \(error.reason)")
        }
    }

    private func map(_ error: LeoDaemonError) -> LeoPluginFetchError {
        switch error {
        case .daemon(code: "not_found", _, _): .credentialMachineUnavailable("\(machine)'s Leo is too old to share accounts")
        case .decoding: .network("\(machine) sent an unexpected reply")
        case .daemon: .credentialMachineUnavailable("\(machine) is unavailable")
        default: .credentialMachineUnavailable("\(machine) is offline")
        }
    }

    private static func response(from reply: LeoCredentialFetchReply) throws -> LeoPluginFetchResponse {
        guard reply.body.count <= LeoPluginFetcher.maxBodyBytes else {
            throw LeoPluginFetchError.bodyTooLarge(limit: LeoPluginFetcher.maxBodyBytes)
        }
        var headers: [String: String] = [:]
        for header in reply.headers {
            let name = header.name.lowercased()
            headers[name] = headers[name].map { $0 + ", " + header.value } ?? header.value
        }
        return LeoPluginFetchResponse(status: reply.status, headers: headers, data: reply.body)
    }
}
