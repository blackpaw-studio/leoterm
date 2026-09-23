import Foundation

/// Pure SFTP v3 packet encoding/decoding -- no I/O. Requests come out as
/// complete frames (length prefix included); replies go in as the payloads
/// `LeoSFTPFramer` produces (type byte onward).
enum LeoSFTPCodec {
    static let protocolVersion: UInt32 = 3

    static func encodeInit() -> Data {
        var body = LeoSFTPWriter()
        body.byte(LeoSFTPPacketType.initialize.rawValue)
        body.uint32(protocolVersion)
        return frame(body.data)
    }

    static func encode(_ request: LeoSFTPRequest, id: UInt32) -> Data {
        var body = LeoSFTPWriter()
        body.byte(packetType(of: request).rawValue)
        body.uint32(id)
        writeFields(of: request, into: &body)
        return frame(body.data)
    }

    static func decodeVersion(_ payload: Data) throws -> LeoSFTPServerVersion {
        var reader = LeoSFTPReader(payload)
        let type = try reader.byte()
        guard type == LeoSFTPPacketType.version.rawValue else { throw LeoSFTPCodecError.unexpectedType(type) }
        let version = try reader.uint32()
        var extensions: [String: Data] = [:]
        while !reader.isAtEnd {
            let name = try reader.text()
            extensions[name] = try reader.string()
        }
        return LeoSFTPServerVersion(version: version, extensions: extensions)
    }

    static func decodeReply(_ payload: Data) throws -> LeoSFTPReply {
        var reader = LeoSFTPReader(payload)
        let rawType = try reader.byte()
        let id = try reader.uint32()
        let response: LeoSFTPResponse
        switch LeoSFTPPacketType(rawValue: rawType) {
        case .status: response = .status(try decodeStatus(&reader))
        case .handle: response = .handle(try reader.string())
        case .data: response = .data(try reader.string())
        case .name: response = .names(try decodeNames(&reader))
        case .attrs: response = .attributes(try decodeAttributes(&reader))
        case .extendedReply: response = .extendedReply(reader.remainder())
        default: throw LeoSFTPCodecError.unexpectedType(rawType)
        }
        return LeoSFTPReply(id: id, response: response)
    }

    // MARK: - Encoding

    private static func frame(_ body: Data) -> Data {
        var framed = LeoSFTPWriter()
        framed.string(body)
        return framed.data
    }

    private static func packetType(of request: LeoSFTPRequest) -> LeoSFTPPacketType {
        switch request {
        case .open: .open
        case .close: .close
        case .read: .read
        case .write: .write
        case .lstat: .lstat
        case .fsetstat: .fsetstat
        case .opendir: .opendir
        case .readdir: .readdir
        case .remove: .remove
        case .realpath: .realpath
        case .stat: .stat
        case .rename: .rename
        case .posixRename: .extended
        }
    }

    private static func writeFields(of request: LeoSFTPRequest, into body: inout LeoSFTPWriter) {
        switch request {
        case let .open(path, flags, attributes):
            body.string(path)
            body.uint32(flags.rawValue)
            writeAttributes(attributes, into: &body)
        case let .close(handle), let .readdir(handle):
            body.string(handle)
        case let .read(handle, offset, length):
            body.string(handle)
            body.uint64(offset)
            body.uint32(length)
        case let .write(handle, offset, data):
            body.string(handle)
            body.uint64(offset)
            body.string(data)
        case let .fsetstat(handle, attributes):
            body.string(handle)
            writeAttributes(attributes, into: &body)
        case let .lstat(path), let .opendir(path), let .remove(path), let .realpath(path), let .stat(path):
            body.string(path)
        case let .rename(from, to):
            body.string(from)
            body.string(to)
        case let .posixRename(from, to):
            body.string(LeoSFTPServerVersion.posixRename)
            body.string(from)
            body.string(to)
        }
    }

    private static func writeAttributes(_ attributes: LeoSFTPAttributes, into body: inout LeoSFTPWriter) {
        var flags: UInt32 = 0
        if attributes.size != nil { flags |= LeoSFTPAttributes.sizeFlag }
        if attributes.owner != nil { flags |= LeoSFTPAttributes.ownerFlag }
        if attributes.permissions != nil { flags |= LeoSFTPAttributes.permissionsFlag }
        if attributes.times != nil { flags |= LeoSFTPAttributes.timesFlag }
        if !attributes.extended.isEmpty { flags |= LeoSFTPAttributes.extendedFlag }
        body.uint32(flags)
        if let size = attributes.size { body.uint64(size) }
        if let owner = attributes.owner {
            body.uint32(owner.uid)
            body.uint32(owner.gid)
        }
        if let permissions = attributes.permissions { body.uint32(permissions) }
        if let times = attributes.times {
            body.uint32(times.accessed)
            body.uint32(times.modified)
        }
        guard !attributes.extended.isEmpty else { return }
        body.uint32(UInt32(attributes.extended.count))
        for pair in attributes.extended {
            body.string(pair.name)
            body.string(pair.data)
        }
    }

    // MARK: - Decoding

    /// The message and language tag are optional in practice: some servers
    /// send a bare status code.
    private static func decodeStatus(_ reader: inout LeoSFTPReader) throws -> LeoSFTPStatus {
        let code = LeoSFTPStatusCode(rawValue: try reader.uint32())
        let message = reader.isAtEnd ? "" : try reader.text()
        return LeoSFTPStatus(code: code, message: message)
    }

    private static func decodeNames(_ reader: inout LeoSFTPReader) throws -> [LeoSFTPName] {
        try repeated(try reader.uint32()) {
            LeoSFTPName(filename: try reader.text(), longname: try reader.text(), attributes: try decodeAttributes(&reader))
        }
    }

    private static func decodeAttributes(_ reader: inout LeoSFTPReader) throws -> LeoSFTPAttributes {
        let flags = try reader.uint32()
        var attributes = LeoSFTPAttributes()
        if flags & LeoSFTPAttributes.sizeFlag != 0 { attributes.size = try reader.uint64() }
        if flags & LeoSFTPAttributes.ownerFlag != 0 {
            attributes.owner = .init(uid: try reader.uint32(), gid: try reader.uint32())
        }
        if flags & LeoSFTPAttributes.permissionsFlag != 0 { attributes.permissions = try reader.uint32() }
        if flags & LeoSFTPAttributes.timesFlag != 0 {
            attributes.times = .init(accessed: try reader.uint32(), modified: try reader.uint32())
        }
        if flags & LeoSFTPAttributes.extendedFlag != 0 {
            attributes.extended = try repeated(try reader.uint32()) { .init(name: try reader.text(), data: try reader.string()) }
        }
        return attributes
    }

    /// Not `(0..<count).map`: that reserves `count` slots up front, and
    /// `count` is an untrusted `uint32` straight off the wire.
    private static func repeated<T>(_ count: UInt32, _ decode: () throws -> T) rethrows -> [T] {
        var items: [T] = []
        for _ in 0..<count { items.append(try decode()) }
        return items
    }
}
