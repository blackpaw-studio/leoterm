import Foundation
import Testing

@testable import Ghostty

/// A server's DATA reply may be shorter than the READ asked for, never
/// longer: extra bytes would be stitched into the file at the wrong offset.
struct LeoSFTPReadReplyTests {
    @Test func aDataReplyLongerThanTheRequestedChunkIsAProtocolError() async throws {
        let launcher = LeoFakeSFTPLauncher(fileSize: 8, extraBytesPerRead: 1)
        let access = LeoFileAccessor.sftp(launcher: launcher, options: .init(chunkSize: 4, maxRequestsInFlight: 2))

        await #expect(throws: LeoFileAccessError.protocolError("a 4-byte read returned 5 bytes")) {
            try await access.read("/f.bin", maxBytes: 100)
        }
        await access.close()
    }

    @Test func exactAndShortRepliesStillReadTheWholeFile() async throws {
        let launcher = LeoFakeSFTPLauncher(fileSize: 10, extraBytesPerRead: 0)
        let access = LeoFileAccessor.sftp(launcher: launcher, options: .init(chunkSize: 4, maxRequestsInFlight: 2))

        let contents = try await access.read("/f.bin", maxBytes: 100)

        #expect(contents.data == LeoFakeSFTPServer.content(count: 10))
        await access.close()
    }
}

/// Launches a `LeoFakeSFTPServer` in-process over pipes.
struct LeoFakeSFTPLauncher: LeoSFTPLaunching {
    let fileSize: Int
    let extraBytesPerRead: Int
    var dropAfterReads: Int?

    func launch() throws -> LeoSFTPChannel {
        LeoFakeSFTPServer(fileSize: fileSize, extraBytesPerRead: extraBytesPerRead, dropAfterReads: dropAfterReads).start()
    }
}

/// Just enough SFTP v3 to serve one file of `fileSize` bytes: INIT, STAT,
/// OPEN, READ, CLOSE. Each READ is answered with up to `length +
/// extraBytesPerRead` bytes -- a misbehaving server when that is nonzero.
/// With `dropAfterReads`, the connection is cut off (as a dropped
/// ControlMaster would) once that many DATA replies have been sent.
final class LeoFakeSFTPServer: @unchecked Sendable {
    private let fileSize: Int
    private let extraBytesPerRead: Int
    private let dropAfterReads: Int?
    private let requests = Pipe()
    private let replies = Pipe()

    init(fileSize: Int, extraBytesPerRead: Int, dropAfterReads: Int? = nil) {
        self.fileSize = fileSize
        self.extraBytesPerRead = extraBytesPerRead
        self.dropAfterReads = dropAfterReads
    }

    static func content(count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &+ 1) })
    }

    func start() -> LeoSFTPChannel {
        Thread.detachNewThread { [self] in serve() }
        let requests = requests
        let replies = replies
        return LeoSFTPChannel(fromServer: replies.fileHandleForReading, toServer: requests.fileHandleForWriting) {
            try? requests.fileHandleForWriting.close()
        }
    }

    private func serve() {
        var framer = LeoSFTPFramer()
        let input = requests.fileHandleForReading
        defer { try? replies.fileHandleForWriting.close() }
        var dataReplies = 0
        while true {
            let chunk = input.availableData
            guard !chunk.isEmpty else { return }
            framer.append(chunk)
            while let packet = try? framer.nextPacket() {
                guard let reply = try? reply(to: packet) else { return }
                if reply.first == LeoSFTPPacketType.data.rawValue {
                    if let dropAfterReads, dataReplies == dropAfterReads { return }
                    dataReplies += 1
                }
                var framed = LeoSFTPWriter()
                framed.string(reply)
                replies.fileHandleForWriting.write(framed.data)
            }
        }
    }

    private func reply(to packet: Data) throws -> Data {
        var reader = LeoSFTPReader(packet)
        let type = try reader.byte()
        var body = LeoSFTPWriter()
        if type == LeoSFTPPacketType.initialize.rawValue {
            body.byte(LeoSFTPPacketType.version.rawValue)
            body.uint32(3)
            return body.data
        }
        let id = try reader.uint32()
        switch LeoSFTPPacketType(rawValue: type) {
        case .stat, .lstat:
            body.byte(LeoSFTPPacketType.attrs.rawValue)
            body.uint32(id)
            body.uint32(LeoSFTPAttributes.sizeFlag | LeoSFTPAttributes.permissionsFlag | LeoSFTPAttributes.timesFlag)
            body.uint64(UInt64(fileSize))
            body.uint32(0o100644)
            body.uint32(0)
            body.uint32(0)
        case .open:
            body.byte(LeoSFTPPacketType.handle.rawValue)
            body.uint32(id)
            body.string(Data("h".utf8))
        case .read:
            _ = try reader.string()
            let offset = Int(try reader.uint64())
            let length = Int(try reader.uint32())
            guard offset < fileSize else { return Self.status(id: id, code: 1) }
            let content = Self.content(count: fileSize + extraBytesPerRead)
            body.byte(LeoSFTPPacketType.data.rawValue)
            body.uint32(id)
            body.string(content.subdata(in: offset..<min(offset + length + extraBytesPerRead, content.count)))
        default:
            return Self.status(id: id, code: 0)
        }
        return body.data
    }

    private static func status(id: UInt32, code: UInt32) -> Data {
        var body = LeoSFTPWriter()
        body.byte(LeoSFTPPacketType.status.rawValue)
        body.uint32(id)
        body.uint32(code)
        body.string("")
        body.string("")
        return body.data
    }
}
