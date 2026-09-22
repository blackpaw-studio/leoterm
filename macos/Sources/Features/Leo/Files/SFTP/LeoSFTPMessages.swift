import Foundation

/// SFTP v3 message types (draft-ietf-secsh-filexfer-02 §3) this client speaks.
enum LeoSFTPPacketType: UInt8 {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case realpath = 16
    case stat = 17
    case rename = 18
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attrs = 105
    case extended = 200
    case extendedReply = 201
}

struct LeoSFTPOpenFlags: OptionSet, Sendable {
    let rawValue: UInt32

    static let read = LeoSFTPOpenFlags(rawValue: 0x01)
    static let write = LeoSFTPOpenFlags(rawValue: 0x02)
    static let append = LeoSFTPOpenFlags(rawValue: 0x04)
    static let create = LeoSFTPOpenFlags(rawValue: 0x08)
    static let truncate = LeoSFTPOpenFlags(rawValue: 0x10)
    static let exclusive = LeoSFTPOpenFlags(rawValue: 0x20)
}

/// The v3 ATTRS structure. Each optional group is present on the wire iff
/// its flag bit is set; `uid`/`gid` and `atime`/`mtime` travel as pairs.
struct LeoSFTPAttributes: Equatable, Sendable {
    struct Owner: Equatable, Sendable {
        let uid: UInt32
        let gid: UInt32
    }

    struct Times: Equatable, Sendable {
        let accessed: UInt32
        let modified: UInt32
    }

    struct Extension: Equatable, Sendable {
        let name: String
        let data: Data
    }

    static let sizeFlag: UInt32 = 0x0000_0001
    static let ownerFlag: UInt32 = 0x0000_0002
    static let permissionsFlag: UInt32 = 0x0000_0004
    static let timesFlag: UInt32 = 0x0000_0008
    static let extendedFlag: UInt32 = 0x8000_0000

    var size: UInt64?
    var owner: Owner?
    /// Full `st_mode`, including the `S_IFMT` file-type bits.
    var permissions: UInt32?
    var times: Times?
    var extended: [Extension] = []

    /// `.other` when the server left permissions out.
    var kind: LeoFileKind {
        guard let permissions else { return .other }
        return LeoFileKind(mode: permissions)
    }
}

enum LeoSFTPRequest: Equatable, Sendable {
    case open(path: String, flags: LeoSFTPOpenFlags, attributes: LeoSFTPAttributes)
    case close(handle: Data)
    case read(handle: Data, offset: UInt64, length: UInt32)
    case write(handle: Data, offset: UInt64, data: Data)
    case lstat(path: String)
    case fsetstat(handle: Data, attributes: LeoSFTPAttributes)
    case opendir(path: String)
    case readdir(handle: Data)
    case remove(path: String)
    case realpath(path: String)
    case stat(path: String)
    case rename(from: String, to: String)
    /// `posix-rename@openssh.com`: rename(2) semantics, replacing `to`
    /// atomically. Only valid when the server advertised the extension.
    case posixRename(from: String, to: String)
}

enum LeoSFTPStatusCode: Equatable, Sendable {
    case ok
    case eof
    case noSuchFile
    case permissionDenied
    case failure
    case badMessage
    case noConnection
    case connectionLost
    case unsupported
    case other(UInt32)

    init(rawValue: UInt32) {
        let known: [LeoSFTPStatusCode] = [
            .ok, .eof, .noSuchFile, .permissionDenied, .failure,
            .badMessage, .noConnection, .connectionLost, .unsupported
        ]
        self = rawValue < known.count ? known[Int(rawValue)] : .other(rawValue)
    }
}

struct LeoSFTPStatus: Equatable, Sendable {
    let code: LeoSFTPStatusCode
    let message: String
}

struct LeoSFTPName: Equatable, Sendable {
    let filename: String
    let longname: String
    let attributes: LeoSFTPAttributes
}

enum LeoSFTPResponse: Equatable, Sendable {
    case status(LeoSFTPStatus)
    case handle(Data)
    case data(Data)
    case names([LeoSFTPName])
    case attributes(LeoSFTPAttributes)
    case extendedReply(Data)
}

/// A response correlated to the request `id` it answers.
struct LeoSFTPReply: Equatable, Sendable {
    let id: UInt32
    let response: LeoSFTPResponse
}

/// The server's `SSH_FXP_VERSION`: protocol version plus advertised
/// extensions (name -> data, e.g. `"posix-rename@openssh.com": "1"`).
struct LeoSFTPServerVersion: Equatable, Sendable {
    let version: UInt32
    let extensions: [String: Data]

    static let posixRename = "posix-rename@openssh.com"

    var supportsPosixRename: Bool { extensions[Self.posixRename] != nil }
}
