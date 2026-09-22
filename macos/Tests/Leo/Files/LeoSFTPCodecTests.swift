import Foundation
import Testing

@testable import Ghostty

/// Byte-level fixtures for the SFTP v3 codec (draft-ietf-secsh-filexfer-02).
/// Every expected packet below is written out by hand from the draft, not
/// produced by the encoder under test.
struct LeoSFTPCodecTests {
    // MARK: - Requests

    @Test func encodesInitForVersionThree() {
        #expect(LeoSFTPCodec.encodeInit() == leoHex("00000005 01 00000003"))
    }

    @Test func encodesOpenForReadingWithEmptyAttributes() {
        let packet = LeoSFTPCodec.encode(.open(path: "/a", flags: [.read], attributes: .init()), id: 1)
        #expect(packet == leoHex("00000013 03 00000001 00000002 2f61 00000001 00000000"))
    }

    @Test func encodesExclusiveCreateWithPermissions() {
        let packet = LeoSFTPCodec.encode(
            .open(path: "/a", flags: [.write, .create, .truncate, .exclusive], attributes: .init(permissions: 0o600)),
            id: 2
        )
        #expect(packet == leoHex("00000017 03 00000002 00000002 2f61 0000003a 00000004 00000180"))
    }

    @Test func encodesReadWithSixtyFourBitOffset() {
        let packet = LeoSFTPCodec.encode(.read(handle: Data("h1".utf8), offset: 1 << 32, length: 32768), id: 7)
        #expect(packet == leoHex("00000017 05 00000007 00000002 6831 0000000100000000 00008000"))
    }

    @Test func encodesWriteWithLengthPrefixedData() {
        let packet = LeoSFTPCodec.encode(.write(handle: Data("h".utf8), offset: 5, data: Data("xyz".utf8)), id: 2)
        #expect(packet == leoHex("00000019 06 00000002 00000001 68 0000000000000005 00000003 78797a"))
    }

    @Test func encodesFsetstatPermissions() {
        let packet = LeoSFTPCodec.encode(.fsetstat(handle: Data("h".utf8), attributes: .init(permissions: 0o644)), id: 3)
        #expect(packet == leoHex("00000012 0a 00000003 00000001 68 00000004 000001a4"))
    }

    @Test func encodesPathOnlyRequestsWithTheirTypeBytes() {
        let cases: [(LeoSFTPRequest, String)] = [
            (.lstat(path: "/a"), "07"), (.opendir(path: "/a"), "0b"), (.remove(path: "/a"), "0d"),
            (.realpath(path: "/a"), "10"), (.stat(path: "/a"), "11")
        ]
        for (request, type) in cases {
            #expect(LeoSFTPCodec.encode(request, id: 4) == leoHex("0000000b \(type) 00000004 00000002 2f61"))
        }
    }

    @Test func encodesHandleOnlyRequests() {
        #expect(LeoSFTPCodec.encode(.close(handle: Data("h".utf8)), id: 5) == leoHex("0000000a 04 00000005 00000001 68"))
        #expect(LeoSFTPCodec.encode(.readdir(handle: Data("h".utf8)), id: 5) == leoHex("0000000a 0c 00000005 00000001 68"))
    }

    @Test func encodesRenameAndPosixRenameExtension() {
        #expect(LeoSFTPCodec.encode(.rename(from: "a", to: "b"), id: 6) == leoHex("0000000f 12 00000006 00000001 61 00000001 62"))
        let posix = LeoSFTPCodec.encode(.posixRename(from: "a", to: "b"), id: 9)
        let name = "706f7369782d72656e616d65406f70656e7373682e636f6d" // posix-rename@openssh.com
        #expect(posix == leoHex("0000002b c8 00000009 00000018 \(name) 00000001 61 00000001 62"))
    }

    @Test func encodesEveryAttributeFieldInFlagOrder() {
        let attributes = LeoSFTPAttributes(
            size: 258,
            owner: .init(uid: 501, gid: 20),
            permissions: 0o100644,
            times: .init(accessed: 1, modified: 2),
            extended: [.init(name: "x", data: Data("y".utf8))]
        )
        let packet = LeoSFTPCodec.encode(.fsetstat(handle: Data(), attributes: attributes), id: 1)
        let body = "8000000f 0000000000000102 000001f5 00000014 000081a4 00000001 00000002 00000001 00000001 78 00000001 79"
        #expect(packet == leoHex("00000037 0a 00000001 00000000 \(body)"))
    }

    // MARK: - Replies

    @Test func decodesVersionWithExtensions() throws {
        let payload = leoHex("02 00000003 00000018 706f7369782d72656e616d65406f70656e7373682e636f6d 00000001 31")
        let version = try LeoSFTPCodec.decodeVersion(payload)
        #expect(version.version == 3)
        #expect(version.extensions == ["posix-rename@openssh.com": Data("1".utf8)])
    }

    @Test func rejectsANonVersionFirstPacket() {
        #expect(throws: LeoSFTPCodecError.unexpectedType(101)) {
            try LeoSFTPCodec.decodeVersion(leoHex("65 00000001 00000000"))
        }
    }

    @Test func decodesStatusWithMessage() throws {
        let reply = try LeoSFTPCodec.decodeReply(leoHex("65 00000004 00000002 0000000c 4e6f20737563682066696c65 00000000"))
        #expect(reply == LeoSFTPReply(id: 4, response: .status(.init(code: .noSuchFile, message: "No such file"))))
    }

    @Test func decodesStatusWithoutTheOptionalMessageFields() throws {
        let reply = try LeoSFTPCodec.decodeReply(leoHex("65 00000004 00000001"))
        #expect(reply == LeoSFTPReply(id: 4, response: .status(.init(code: .eof, message: ""))))
    }

    @Test func mapsEveryStatusCode() {
        let codes: [UInt32: LeoSFTPStatusCode] = [
            0: .ok, 1: .eof, 2: .noSuchFile, 3: .permissionDenied, 4: .failure,
            5: .badMessage, 6: .noConnection, 7: .connectionLost, 8: .unsupported, 42: .other(42)
        ]
        for (raw, code) in codes { #expect(LeoSFTPStatusCode(rawValue: raw) == code) }
    }

    @Test func decodesHandleDataAndExtendedReply() throws {
        #expect(try LeoSFTPCodec.decodeReply(leoHex("66 00000002 00000002 6831")) == LeoSFTPReply(id: 2, response: .handle(Data("h1".utf8))))
        #expect(try LeoSFTPCodec.decodeReply(leoHex("67 00000003 00000003 78797a")) == LeoSFTPReply(id: 3, response: .data(Data("xyz".utf8))))
        #expect(try LeoSFTPCodec.decodeReply(leoHex("c9 00000004 0102")) == LeoSFTPReply(id: 4, response: .extendedReply(leoHex("0102"))))
    }

    @Test func decodesNamesWithFullAttributes() throws {
        let attributes = "0000000f 0000000000000102 000001f5 00000014 000081a4 00000001 00000002"
        let payload = leoHex("68 00000005 00000001 00000005 662e747874 00000002 2d72 \(attributes)")
        let reply = try LeoSFTPCodec.decodeReply(payload)
        let expected = LeoSFTPName(
            filename: "f.txt",
            longname: "-r",
            attributes: .init(size: 258, owner: .init(uid: 501, gid: 20), permissions: 0o100644, times: .init(accessed: 1, modified: 2))
        )
        #expect(reply == LeoSFTPReply(id: 5, response: .names([expected])))
    }

    @Test func decodesAttributesWithExtendedPairs() throws {
        let payload = leoHex("69 00000006 80000004 000041ed 00000001 00000001 6b 00000002 7676")
        let reply = try LeoSFTPCodec.decodeReply(payload)
        let attributes = LeoSFTPAttributes(permissions: 0o40755, extended: [.init(name: "k", data: Data("vv".utf8))])
        #expect(reply == LeoSFTPReply(id: 6, response: .attributes(attributes)))
    }

    @Test func attributesReportFileKind() {
        #expect(LeoSFTPAttributes(permissions: 0o100644).kind == .file)
        #expect(LeoSFTPAttributes(permissions: 0o040755).kind == .directory)
        #expect(LeoSFTPAttributes(permissions: 0o120777).kind == .symlink)
        #expect(LeoSFTPAttributes(permissions: 0o010644).kind == .other)
        #expect(LeoSFTPAttributes().kind == .other)
    }

    @Test func rejectsTruncatedAndUnknownReplies() {
        #expect(throws: LeoSFTPCodecError.truncated) { try LeoSFTPCodec.decodeReply(leoHex("66 00000002 00000009 6831")) }
        #expect(throws: LeoSFTPCodecError.truncated) { try LeoSFTPCodec.decodeReply(leoHex("69 00000006 00000001 0000")) }
        #expect(throws: LeoSFTPCodecError.unexpectedType(3)) { try LeoSFTPCodec.decodeReply(leoHex("03 00000001")) }
        #expect(throws: LeoSFTPCodecError.truncated) { try LeoSFTPCodec.decodeReply(Data()) }
    }

    // MARK: - Framing

    @Test func framerReassemblesPacketsSplitAcrossReads() throws {
        var framer = LeoSFTPFramer()
        let stream = leoHex("00000005 02 00000003 00000009 67 00000001 00000000")
        framer.append(stream.prefix(3))
        #expect(try framer.nextPacket() == nil)
        framer.append(stream.dropFirst(3).prefix(10))
        #expect(try framer.nextPacket() == leoHex("02 00000003"))
        #expect(try framer.nextPacket() == nil)
        framer.append(stream.dropFirst(13))
        #expect(try framer.nextPacket() == leoHex("67 00000001 00000000"))
        #expect(try framer.nextPacket() == nil)
    }

    @Test func framerRejectsEmptyAndOversizedPackets() {
        var empty = LeoSFTPFramer()
        empty.append(leoHex("00000000"))
        #expect(throws: LeoSFTPCodecError.badLength(0)) { try empty.nextPacket() }

        var huge = LeoSFTPFramer()
        huge.append(leoHex("7fffffff 67"))
        #expect(throws: LeoSFTPCodecError.badLength(0x7fff_ffff)) { try huge.nextPacket() }
    }
}

/// Parses whitespace-separated hex into bytes. Test fixtures only.
func leoHex(_ text: String) -> Data {
    let digits = text.filter { !$0.isWhitespace }
    var bytes: [UInt8] = []
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        bytes.append(UInt8(digits[index..<next], radix: 16)!)
        index = next
    }
    return Data(bytes)
}
