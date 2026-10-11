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

/// Status, headers (keys lowercased) and body.
public struct LeoFileResponse: Equatable, Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
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
    case http(Int)
    case malformed(String)
}

extension LeoFileDownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noLongerAvailable: "No longer available"
        case .unreadable: "The daemon can't read this file."
        case .unauthorized: "This device's token was rejected. Pair it again."
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

    public func download(id: String, to url: URL, maxBytes: Int64) async throws -> LeoDownloadedFile {
        let path = "/api/v1/files/\(try LeoSocketDaemonClient.pathSegment(id))"
        let head = try Self.checked(try await transport.fetch(LeoFileRequest(method: "HEAD", path: path), timeout: Self.timeout))
        guard let total = head.headers["content-length"].flatMap(Int64.init), total >= 0 else {
            throw LeoFileDownloadError.malformed("no Content-Length")
        }
        let wanted = min(total, max(0, maxBytes))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path(), contents: nil) else {
            throw LeoFileDownloadError.malformed("can't create \(url.lastPathComponent)")
        }
        do {
            let written = try await fetchBody(path: path, total: total, wanted: wanted, into: url)
            return LeoDownloadedFile(url: url, totalBytes: total, byteCount: written, contentType: head.headers["content-type"])
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Writes the first `wanted` bytes; returns how many it wrote (fewer if
    /// the file shrank since the `HEAD`).
    private func fetchBody(path: String, total: Int64, wanted: Int64, into url: URL) async throws -> Int64 {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        if wanted == total, total <= chunkSize {
            let body = try Self.checked(try await transport.fetch(LeoFileRequest(method: "GET", path: path), timeout: Self.timeout)).body
            let data = body.prefix(Int(wanted))
            try handle.write(contentsOf: data)
            return Int64(data.count)
        }
        var offset: Int64 = 0
        while offset < wanted {
            try Task.checkCancellation()
            let range = offset...min(offset + chunkSize, wanted) - 1
            let response = try await transport.fetch(LeoFileRequest(method: "GET", path: path, range: range), timeout: Self.timeout)
            if response.status == 416 { break }
            let checked = try Self.checked(response)
            // A server that ignores Range sends the whole file from byte 0.
            let isWhole = checked.status == 200
            if !isWhole, Self.rangeStart(checked.headers["content-range"]) != offset {
                throw LeoFileDownloadError.malformed("unexpected Content-Range")
            }
            let body = isWhole ? checked.body.dropFirst(Int(offset)) : checked.body
            let data = body.prefix(Int(wanted - offset))
            guard !data.isEmpty else { break }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            if isWhole { break }
        }
        return offset
    }

    /// The first offset of `bytes A-B/T`.
    private static func rangeStart(_ header: String?) -> Int64? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        return header.dropFirst("bytes ".count).split(separator: "-").first.flatMap { Int64($0) }
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
            let (data, response) = try await session.data(for: urlRequest, delegate: redirects)
            try redirects.checkNoneRefused()
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { result, field in
                if let key = field.key as? String, let value = field.value as? String { result[key.lowercased()] = value }
            }
            return LeoFileResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
        } catch let error as URLError {
            throw Self.transportError(error)
        }
    }
}
