import Foundation

public enum LeoPluginWireError: Error, Equatable, CustomStringConvertible, Sendable {
    /// A frame (declared or actual) is over the limit for its direction.
    case tooLarge(bytes: Int, limit: Int)
    case notUTF8
    /// The peer closed in the middle of a frame.
    case truncated
    case io(errno: Int32)

    public var description: String {
        switch self {
        case .tooLarge(let bytes, let limit): "frame is \(bytes) bytes; limit is \(limit)"
        case .notUTF8: "frame is not valid UTF-8"
        case .truncated: "connection closed mid-frame"
        case .io(let code): "I/O error \(code)"
        }
    }
}

/// App → host: the bundle to load, or an event to deliver. Wire form:
/// `{"op":"load","source":"…"}` / `{"op":"deliver","event":{…}}`.
public enum LeoPluginHostCommand: Codable, Equatable, Sendable {
    case load(source: String)
    case deliver(LeoPluginEvent)

    private enum CodingKeys: String, CodingKey { case op, source, event }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .op) {
        case "load": self = .load(source: try c.decode(String.self, forKey: .source))
        case "deliver": self = .deliver(try c.decode(LeoPluginEvent.self, forKey: .event))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .load(let source):
            try c.encode("load", forKey: .op)
            try c.encode(source, forKey: .source)
        case .deliver(let event):
            try c.encode("deliver", forKey: .op)
            try c.encode(event, forKey: .event)
        }
    }
}

/// Host → app: a bridge request from plugin code, or the helper's marker that
/// it finished one command (a `load` or a `deliver`), which the app's watchdog
/// uses to bound each handler's CPU.
public enum LeoPluginHostMessage: Equatable, Sendable {
    case request(LeoPluginHostRequest)
    case handlerDone

    /// Decodes one host → app frame. The byte cap is checked before parsing.
    public static func decode(frame: Data) throws -> LeoPluginHostMessage {
        if frame == LeoPluginWire.doneFrame { return .handlerDone }
        guard frame.count <= LeoPluginFrameLimits.maxFrameBytes else {
            throw LeoPluginFrameError.tooLarge(bytes: frame.count)
        }
        guard let json = String(data: frame, encoding: .utf8) else { throw LeoPluginWireError.notUTF8 }
        return .request(try LeoPluginFrame.decodeRequest(json))
    }
}

/// Length-prefixed framing for the app ↔ helper socketpair: a u32 big-endian
/// byte count, then that many bytes of UTF-8 JSON.
public enum LeoPluginWire {
    /// Host → app cap: the same as the bridge's per-frame limit.
    public static let maxHostToAppBytes = LeoPluginFrameLimits.maxFrameBytes
    /// App → host cap. Covers a bundle of up to 10 MB (the installer's limit)
    /// after JSON escaping, plus the envelope.
    public static let maxAppToHostBytes = 16 * 1_048_576
    /// The host's per-command acknowledgement. Matched byte for byte; plugin
    /// code cannot produce it (its frames always start with `{"call"`).
    public static let doneFrame = Data(#"{"done":1}"#.utf8)

    public static func encode(_ payload: Data, limit: Int) throws -> Data {
        guard payload.count <= limit else { throw LeoPluginWireError.tooLarge(bytes: payload.count, limit: limit) }
        var framed = Data(capacity: payload.count + 4)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }

    // MARK: Blocking file descriptor I/O (the helper's loop and tests)

    /// Writes every byte, retrying on `EINTR`. SIGPIPE must be ignored by the caller.
    public static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw LeoPluginWireError.io(errno: errno)
                }
                offset += written
            }
        }
    }

    /// Reads one frame. `nil` is a clean EOF between frames. The declared length
    /// is checked against `limit` before any body byte is read or allocated.
    public static func readFrame(from fd: Int32, limit: Int) throws -> Data? {
        guard let header = try readExactly(4, from: fd, allowEOFAtStart: true) else { return nil }
        let length = Int(header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard length <= limit else { throw LeoPluginWireError.tooLarge(bytes: length, limit: limit) }
        if length == 0 { return Data() }
        guard let body = try readExactly(length, from: fd, allowEOFAtStart: false) else {
            throw LeoPluginWireError.truncated
        }
        return body
    }

    private static func readExactly(_ count: Int, from fd: Int32, allowEOFAtStart: Bool) throws -> Data? {
        var buffer = Data(count: count)
        var offset = 0
        try buffer.withUnsafeMutableBytes { raw in
            while offset < count {
                let got = read(fd, raw.baseAddress! + offset, count - offset)
                if got < 0 {
                    if errno == EINTR { continue }
                    throw LeoPluginWireError.io(errno: errno)
                }
                if got == 0 { return }
                offset += got
            }
        }
        if offset == count { return buffer }
        if offset == 0 && allowEOFAtStart { return nil }
        throw LeoPluginWireError.truncated
    }
}

/// Incremental frame decoder for the app side, which reads in chunks from a
/// non-blocking source. Rejects an oversized header immediately, so a hostile
/// host can't make the app buffer a huge body. After an error the reader keeps
/// failing: the connection must be torn down.
public struct LeoPluginFrameReader {
    private let limit: Int
    private var buffer = Data()
    private var failure: LeoPluginWireError?

    public init(limit: Int) { self.limit = limit }

    public mutating func append(_ chunk: Data) throws -> [Data] {
        if let failure { throw failure }
        buffer.append(chunk)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = Int(buffer[start..<start + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard length <= limit else {
                let error = LeoPluginWireError.tooLarge(bytes: length, limit: limit)
                failure = error
                buffer = Data()
                throw error
            }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer[start + 4..<start + 4 + length]))
            buffer = Data(buffer[(start + 4 + length)...])
        }
        return frames
    }
}
