import CryptoKit
import Foundation

/// The phone's AES-256 push key: generated once on the phone, given only to
/// paired daemons, and read by the Notification Service Extension.
public struct LeoPushKey: Equatable, Sendable {
    public static let byteCount = 32

    public let data: Data

    /// Nil unless `data` is exactly 32 bytes.
    public init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        self.data = data
    }

    public init?(base64: String) {
        guard let data = Data(base64Encoded: base64) else { return nil }
        self.init(data: data)
    }

    public static func generate() -> Self {
        // A freshly generated 256-bit key always has the right length.
        Self(unchecked: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// How the key travels to a daemon (`PUT …/push {key}`).
    public var base64: String { data.base64EncodedString() }

    var symmetricKey: SymmetricKey { SymmetricKey(data: data) }

    private init(unchecked data: Data) {
        self.data = data
    }
}
