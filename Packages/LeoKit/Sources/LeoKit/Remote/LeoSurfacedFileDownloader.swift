import Foundation

/// One request against `/api/v1/files/{id}`; `range` becomes a `Range`
/// header (inclusive byte offsets).
public struct LeoFileRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let range: ClosedRange<Int64>?

    public init(method: String, path: String, range: ClosedRange<Int64>? = nil) {
        self.method = method
        self.path = path
        self.range = range
    }
}

/// Status, headers (keys lowercased), and the body read on demand, so a
/// reader can stop at a byte limit without the rest ever being buffered.
public struct LeoFileResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    private let next: @Sendable () async throws -> Data?
    private let stop: @Sendable () -> Void

    public init(
        status: Int, headers: [String: String],
        next: @escaping @Sendable () async throws -> Data?, cancel: @escaping @Sendable () -> Void
    ) {
        self.status = status
        self.headers = headers
        self.next = next
        stop = cancel
    }

    /// A body already in memory, as one chunk.
    public init(status: Int, headers: [String: String], body: Data) {
        let remaining = LockedValue<Data>(body.isEmpty ? nil : body)
        self.init(status: status, headers: headers, next: { remaining.take() }, cancel: {})
    }

    /// The next part of the body, or nil at its end.
    public func nextChunk() async throws -> Data? { try await next() }

    /// Stops the transfer; the rest of the body is never read.
    public func cancel() { stop() }
}

/// A value behind a lock that is read once.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    init(_ value: Value?) { self.value = value }

    func take() -> Value? {
        lock.withLock {
            defer { value = nil }
            return value
        }
    }
}

/// File requests to one daemon. Any HTTP status is a response; only a
/// failure to get one throws.
public protocol LeoFileTransport: Sendable {
    func fetch(_ request: LeoFileRequest, timeout: TimeInterval) async throws -> LeoFileResponse
}

public enum LeoFileDownloadError: Error, Equatable, Sendable {
    /// 404: evicted from the daemon's store (or deleted from disk).
    case noLongerAvailable
    /// 403: not a regular file, or not readable by the daemon.
    case unreadable
    case unauthorized
    /// Larger than the cap for a preview that can't be cut short.
    case tooLarge(Int64)
    case http(Int)
    case malformed(String)
}

extension LeoFileDownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noLongerAvailable: "No longer available"
        case .unreadable: "The daemon can't read this file."
        case .unauthorized: "This device's token was rejected. Pair it again."
        case .tooLarge(let bytes): "At \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)), it's too large to preview on this device."
        case .http(let status): "The daemon answered HTTP \(status)."
        case .malformed(let reason): "The daemon's response was malformed: \(reason)"
        }
    }
}

/// A surfaced file saved locally: all of it, or its first `byteCount`
/// bytes when it was larger than the cap.
public struct LeoDownloadedFile: Equatable, Sendable {
    public let url: URL
    public let totalBytes: Int64
    public let byteCount: Int64
    public let contentType: String?

    public init(url: URL, totalBytes: Int64, byteCount: Int64, contentType: String? = nil) {
        self.url = url
        self.totalBytes = totalBytes
        self.byteCount = byteCount
        self.contentType = contentType
    }

    public var isTruncated: Bool { byteCount < totalBytes }
}

/// Downloads a surfaced file by id: `HEAD` for its size and type, then one
/// plain `GET` for a small whole file or `Range` chunks for a large (or
/// capped) one, appended to `url`. A failure leaves no partial file.
public struct LeoSurfacedFileDownloader: Sendable {
    public static let defaultChunkSize: Int64 = 4 << 20
    static let timeout: TimeInterval = 60

    private let transport: any LeoFileTransport
    private let chunkSize: Int64

    public init(transport: any LeoFileTransport, chunkSize: Int64 = Self.defaultChunkSize) {
        self.transport = transport
        self.chunkSize = max(1, chunkSize)
    }

    /// With `truncating` false, a file over `maxBytes` throws `tooLarge`
    /// (after the `HEAD`, or once a body runs past it) instead of saving its
    /// first `maxBytes`. No more than `maxBytes` is kept, and reading stops
    /// there, whatever the server sends.
    public func download(id: String, to url: URL, maxBytes: Int64, truncating: Bool = true) async throws -> LeoDownloadedFile {
        let path = "/api/v1/files/\(try LeoSocketDaemonClient.pathSegment(id))"
        let head = try Self.checked(try await transport.fetch(LeoFileRequest(method: "HEAD", path: path), timeout: Self.timeout))
        head.cancel()
        guard let total = head.headers["content-length"].flatMap(Int64.init), total >= 0 else {
            throw LeoFileDownloadError.malformed("no Content-Length")
        }
        if !truncating, total > maxBytes { throw LeoFileDownloadError.tooLarge(total) }
        let limit = Limit(wanted: min(total, max(0, maxBytes)), maxBytes: max(0, maxBytes), truncating: truncating)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path(), contents: nil) else {
            throw LeoFileDownloadError.malformed("can't create \(url.lastPathComponent)")
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let (written, size) = try await fetchBody(path: path, total: total, limit: limit, into: handle)
            return LeoDownloadedFile(url: url, totalBytes: size, byteCount: written, contentType: head.headers["content-type"])
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// How much of the body to keep: the first `wanted` bytes (all of it,
    /// as the `HEAD` sized it, when it fits). A file that grew since is read
    /// on, up to `maxBytes`.
    private struct Limit {
        let wanted: Int64
        let maxBytes: Int64
        let truncating: Bool
    }

    /// Writes the body; returns how many bytes it wrote (fewer if the file
    /// shrank since the `HEAD`) and the file's size as the last response
    /// saw it: at least `total`, more if the file grew since the `HEAD`.
    private func fetchBody(path: String, total: Int64, limit: Limit, into handle: FileHandle) async throws -> (written: Int64, size: Int64) {
        if limit.wanted == total, total <= chunkSize {
            let response = try Self.checked(try await transport.fetch(LeoFileRequest(method: "GET", path: path), timeout: Self.timeout))
            return try await whole(response, size: total, limit: limit, into: handle)
        }
        var size = total
        var wanted = limit.wanted
        var offset: Int64 = 0
        while offset < wanted {
            try Task.checkCancellation()
            let range = offset...min(offset + chunkSize, wanted) - 1
            let response = try await transport.fetch(LeoFileRequest(method: "GET", path: path, range: range), timeout: Self.timeout)
            if response.status == 416 {
                response.cancel()
                break
            }
            let checked = try Self.checked(response)
            // A server that ignores Range sends the whole file from byte 0.
            if checked.status == 200 { return try await whole(checked, size: size, limit: limit, into: handle) }
            guard Self.rangeStart(checked.headers["content-range"]) == offset else {
                checked.cancel()
                throw LeoFileDownloadError.malformed("unexpected Content-Range")
            }
            // The file grew since the `HEAD`: read on to its new end.
            if let current = Self.rangeTotal(checked.headers["content-range"]), current > size {
                size = current
                if !limit.truncating, size > limit.maxBytes {
                    checked.cancel()
                    throw LeoFileDownloadError.tooLarge(size)
                }
                wanted = min(size, limit.maxBytes)
            }
            let (written, _) = try await Self.copy(checked, into: handle, upTo: Int64(range.count))
            guard written > 0 else { break }
            offset += written
        }
        return (offset, size)
    }

    /// A body answering for the whole file from byte 0: starts the file
    /// over, and keeps at most `maxBytes` of it. One that runs past that is
    /// refused unless the download may be cut short, in which case the file
    /// is reported larger than what was kept.
    private func whole(_ response: LeoFileResponse, size: Int64, limit: Limit, into handle: FileHandle) async throws -> (written: Int64, size: Int64) {
        let declared = response.headers["content-length"].flatMap(Int64.init) ?? 0
        try handle.truncate(atOffset: 0)
        let (written, isCut) = try await Self.copy(response, into: handle, upTo: limit.maxBytes)
        if isCut, !limit.truncating { throw LeoFileDownloadError.tooLarge(written + 1) }
        return (written, max(size, declared, written, isCut ? written + 1 : 0))
    }

    /// Appends `response`'s body up to `limit` bytes, then stops the
    /// transfer; `isCut` says the body went on past it.
    private static func copy(_ response: LeoFileResponse, into handle: FileHandle, upTo limit: Int64) async throws -> (written: Int64, isCut: Bool) {
        var written: Int64 = 0
        do {
            while let chunk = try await response.nextChunk() {
                try Task.checkCancellation()
                let kept = min(limit - written, Int64(chunk.count))
                try handle.write(contentsOf: chunk.prefix(Int(kept)))
                written += kept
                if kept < Int64(chunk.count) {
                    response.cancel()
                    return (written, true)
                }
            }
            return (written, false)
        } catch {
            response.cancel()
            throw error
        }
    }

    /// The first offset of `bytes A-B/T`.
    private static func rangeStart(_ header: String?) -> Int64? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        return header.dropFirst("bytes ".count).split(separator: "-").first.flatMap { Int64($0) }
    }

    /// The `T` of `bytes A-B/T`; nil when the size is unknown (`*`).
    private static func rangeTotal(_ header: String?) -> Int64? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        return header.split(separator: "/").last.flatMap { Int64($0) }
    }

    private static func checked(_ response: LeoFileResponse) throws -> LeoFileResponse {
        switch response.status {
        case 200..<300: response
        case 401: throw LeoFileDownloadError.unauthorized
        case 403: throw LeoFileDownloadError.unreadable
        case 404, 410: throw LeoFileDownloadError.noLongerAvailable
        default: throw LeoFileDownloadError.http(response.status)
        }
    }
}

extension LeoHTTPSTransport: LeoFileTransport {
    func urlRequest(for request: LeoFileRequest, timeout: TimeInterval) throws -> URLRequest {
        var urlRequest = try urlRequest(for: LeoHTTPRequest(method: request.method, path: request.path), timeout: timeout)
        if let range = request.range {
            urlRequest.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        return urlRequest
    }

    public func fetch(_ request: LeoFileRequest, timeout: TimeInterval) async throws -> LeoFileResponse {
        let urlRequest = try urlRequest(for: request, timeout: timeout)
        let redirects = SameOriginRedirects(origin: endpoint.baseURL)
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest, delegate: redirects)
            try redirects.checkNoneRefused()
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { result, field in
                if let key = field.key as? String, let value = field.value as? String { result[key.lowercased()] = value }
            }
            let reader = ChunkReader(bytes)
            return LeoFileResponse(status: http?.statusCode ?? 0, headers: headers, next: { try await reader.next() }, cancel: { bytes.task.cancel() })
        } catch let error as URLError {
            throw Self.transportError(error)
        }
    }
}

/// Groups a streamed body into chunks as the reader asks for them, so
/// nothing past what has been asked for is held in memory.
private final class ChunkReader: @unchecked Sendable {
    static let chunkSize = 64 << 10

    private var iterator: URLSession.AsyncBytes.AsyncIterator

    init(_ bytes: URLSession.AsyncBytes) { iterator = bytes.makeAsyncIterator() }

    /// Called serially by one reader.
    func next() async throws -> Data? {
        var chunk = Data(capacity: Self.chunkSize)
        do {
            while chunk.count < Self.chunkSize, let byte = try await iterator.next() { chunk.append(byte) }
        } catch let error as URLError {
            throw LeoHTTPSTransport.transportError(error)
        }
        return chunk.isEmpty ? nil : chunk
    }
}
