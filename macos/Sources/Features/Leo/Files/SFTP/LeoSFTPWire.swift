import Foundation

enum LeoSFTPCodecError: Error, Equatable, Sendable {
    case truncated
    case unexpectedType(UInt8)
    /// A frame length of zero, or larger than `LeoSFTPFramer.maxPacketLength`.
    case badLength(UInt32)
}

/// Big-endian encoder for the SSH wire primitives SFTP uses (RFC 4251 §5).
struct LeoSFTPWriter {
    private(set) var data = Data()

    mutating func byte(_ value: UInt8) {
        data.append(value)
    }

    mutating func uint32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func uint64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func string(_ value: Data) {
        uint32(UInt32(value.count))
        data.append(value)
    }

    mutating func string(_ value: String) {
        string(Data(value.utf8))
    }
}

/// Big-endian decoder over one packet's bytes. Every read throws
/// `.truncated` instead of running off the end.
struct LeoSFTPReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func byte() throws -> UInt8 {
        try take(1)[0]
    }

    mutating func uint32() throws -> UInt32 {
        try take(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func uint64() throws -> UInt64 {
        try take(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func string() throws -> Data {
        Data(try take(Int(try uint32())))
    }

    /// SFTP v3 file names are raw bytes; invalid UTF-8 is replaced rather
    /// than failing the whole listing.
    mutating func text() throws -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: try string(), as: UTF8.self)
    }

    /// Everything not yet consumed.
    mutating func remainder() -> Data {
        defer { offset = bytes.count }
        return Data(bytes[min(offset, bytes.count)...])
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, bytes.count - offset >= count else { throw LeoSFTPCodecError.truncated }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }
}

/// Splits the server's byte stream into packets (`uint32 length` + that many
/// bytes). `nextPacket()` returns the payload -- type byte onward -- or nil
/// until a whole packet has arrived.
struct LeoSFTPFramer {
    /// Far above anything this client asks for (32 KiB reads, OpenSSH's
    /// 256 KiB message cap); a larger frame means a desynchronised stream.
    static let maxPacketLength: UInt32 = 1 << 20

    private var buffer: [UInt8] = []

    mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    mutating func nextPacket() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard length > 0, length <= Self.maxPacketLength else { throw LeoSFTPCodecError.badLength(length) }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let payload = Data(buffer[4..<total])
        buffer.removeFirst(total)
        return payload
    }
}
