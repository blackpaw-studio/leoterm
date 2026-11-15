import Foundation
import LeoKit

/// A daemon this device has paired with. Non-secret: it lives in the
/// paired-daemons file; the token lives in the Keychain (`DaemonSecrets`).
public struct PairedDaemon: Codable, Equatable, Identifiable, Sendable {
    /// The daemon's `daemon_id` from `leo pair`.
    public let id: String
    public var name: String
    /// The origin that answered the pairing request; every call goes here.
    public var baseURL: URL
    /// Every origin `leo pair` advertised, in its order.
    public var urls: [URL]
    public var deviceID: String
    public var pairedAt: Date

    public init(id: String, name: String, baseURL: URL, urls: [URL], deviceID: String, pairedAt: Date) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.urls = urls
        self.deviceID = deviceID
        self.pairedAt = pairedAt
    }
}

/// A daemon's credentials: this device's bearer token and, for a daemon
/// behind Cloudflare Access, a service token. Keychain only.
public struct DaemonSecrets: Codable, Equatable, Sendable {
    public var token: String
    public var cfAccess: LeoCFAccessCredentials?

    public init(token: String, cfAccess: LeoCFAccessCredentials? = nil) {
        self.token = token
        self.cfAccess = cfAccess
    }
}

/// Everything a request to one daemon needs.
public struct DaemonConnection: Equatable, Sendable {
    public let daemonID: String
    public let endpoint: LeoRemoteEndpoint

    public init(daemon: PairedDaemon, secrets: DaemonSecrets) {
        daemonID = daemon.id
        endpoint = LeoRemoteEndpoint(baseURL: daemon.baseURL, token: secrets.token, cfAccess: secrets.cfAccess)
    }
}
