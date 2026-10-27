import CryptoKit
import Foundation

/// The identifier of an agent's persistent web data store: a UUIDv5 of
/// `machineID + NUL + agent`, so the same agent on the same machine reopens the
/// same cookies after an agent restart or app relaunch with no lookup table.
public enum LeoBrowserStoreID {
    /// Fixed forever: changing it orphans every agent's stored cookies.
    static let namespace = UUID(uuidString: "5C1D6A3E-7B94-4E0F-A1B2-8F3D2C9E4A70")!

    public static func identifier(machineID: String, agent: String) -> UUID {
        uuidV5(namespace: namespace, name: machineID + "\u{0}" + agent)
    }

    /// RFC 4122 section 4.3.
    static func uuidV5(namespace: UUID, name: String) -> UUID {
        var input = withUnsafeBytes(of: namespace.uuid) { Data($0) }
        input.append(Data(name.utf8))
        var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
