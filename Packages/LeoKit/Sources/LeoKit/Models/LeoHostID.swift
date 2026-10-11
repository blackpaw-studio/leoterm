import Foundation

/// Which daemon a value belongs to: the local one, or a configured remote
/// host by name.
public enum LeoHostID: Hashable, Sendable, Codable {
    case local
    case remote(String)

    public var displayName: String {
        switch self {
        case .local: "localhost"
        case .remote(let name): name
        }
    }
}

/// One agent on one host: the identity attention, focus and rows share.
public struct LeoAgentID: Hashable, Sendable, Codable {
    public let host: LeoHostID
    public let name: String

    public init(host: LeoHostID, name: String) {
        self.host = host
        self.name = name
    }
}
