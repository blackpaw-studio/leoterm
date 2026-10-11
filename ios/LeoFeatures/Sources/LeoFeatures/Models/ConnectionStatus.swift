import Foundation

/// The live connection to one daemon's event stream.
public enum ConnectionStatus: Equatable, Sendable {
    /// Not connected: the app is in the background, or hasn't started yet.
    case offline
    case connecting
    case connected
    /// The stream dropped; the next attempt is scheduled with backoff.
    case reconnecting(attempt: Int, reason: String)
    /// The daemon refused this device's token (revoked or lost); retrying
    /// won't help until the user re-pairs.
    case unauthorized(String)

    public var isConnected: Bool { self == .connected }
}

/// How a connection attempt ended.
public enum StreamEnd: Equatable, Sendable {
    case closed
    case failed(String)
    case unauthorized(String)
    case missingCredentials
}
