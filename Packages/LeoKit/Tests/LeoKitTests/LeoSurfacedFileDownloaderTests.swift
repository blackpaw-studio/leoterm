import Foundation
import Testing

@testable import LeoKit

struct LeoSurfacedFileDownloaderTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "leo-downloader-tests-\(UUID().uuidString)")

    @Test func anEvictedFileIsNoLongerAvailable() async throws {
        let transport = FakeFileTransport(content: nil)
        let destination = directory.appending(path: "a.png")
        await #expect(throws: LeoFileDownloadError.noLongerAvailable) {
            _ = try await LeoSurfacedFileDownloader(transport: transport).download(id: "f1", to: destination, maxBytes: 100)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path()))
    }

    @Test(arguments: [(401, LeoFileDownloadError.unauthorized), (403, .unreadable), (500, .http(500))])
    func mapsOtherStatuses(status: Int, expected: LeoFileDownloadError) async throws {
        let transport = FakeFileTransport(content: nil, status: status)
        await #expect(throws: expected) {
            _ = try await LeoSurfacedFileDownloader(transport: transport).download(id: "f1", to: directory.appending(path: "x"), maxBytes: 100)
        }
    }

    @Test func downloadsLargeFilesInRangeChunks() async throws {
        let content = Data((0..<10).map { UInt8($0) })
        let transport = FakeFileTransport(content: content, contentType: "image/png")
        let destination = directory.appending(path: "img.png")
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = try await LeoSurfacedFileDownloader(transport: transport, chunkSize: 4).download(id: "f1", to: destination, maxBytes: 100)

        #expect(try Data(contentsOf: destination) == content)
        #expect(file == LeoDownloadedFile(url: destination, totalBytes: 10, byteCount: 10, contentType: "image/png"))
        #expect(transport.requests == [
            LeoFileRequest(method: "HEAD", path: "/api/v1/files/f1"),
            LeoFileRequest(method: "GET", path: "/api/v1/files/f1", range: 0...3),
            LeoFileRequest(method: "GET", path: "/api/v1/files/f1", range: 4...7),
            LeoFileRequest(method: "GET", path: "/api/v1/files/f1", range: 8...9),
        ])
    }

    @Test func stopsAtTheCapAndReportsTruncation() async throws {
        let transport = FakeFileTransport(content: Data(repeating: 0x41, count: 10))
        let destination = directory.appending(path: "big.txt")
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = try await LeoSurfacedFileDownloader(transport: transport, chunkSize: 100).download(id: "f1", to: destination, maxBytes: 6)

        #expect(file.byteCount == 6)
        #expect(file.totalBytes == 10)
        #expect(file.isTruncated)
        #expect(try Data(contentsOf: destination).count == 6)
        #expect(transport.requests.last == LeoFileRequest(method: "GET", path: "/api/v1/files/f1", range: 0...5))
    }

    @Test func aSmallWholeFileIsOnePlainGet() async throws {
        let transport = FakeFileTransport(content: Data("# Hi\n".utf8))
        let destination = directory.appending(path: "a.md")
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = try await LeoSurfacedFileDownloader(transport: transport).download(id: "f1", to: destination, maxBytes: 1 << 20)

        #expect(!file.isTruncated)
        #expect(String(decoding: try Data(contentsOf: destination), as: UTF8.self) == "# Hi\n")
        #expect(transport.requests.last == LeoFileRequest(method: "GET", path: "/api/v1/files/f1"))
    }

    @Test func aFileEvictedMidDownloadLeavesNoPartialFile() async throws {
        let transport = FakeFileTransport(content: Data(repeating: 1, count: 10), evictAfterRequests: 2)
        let destination = directory.appending(path: "gone.bin")
        await #expect(throws: LeoFileDownloadError.noLongerAvailable) {
            _ = try await LeoSurfacedFileDownloader(transport: transport, chunkSize: 4).download(id: "f1", to: destination, maxBytes: 100)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path()))
    }

    @Test func anIdThatIsNotAPathSegmentIsRefused() async throws {
        let transport = FakeFileTransport(content: Data())
        await #expect(throws: LeoDaemonError.self) {
            _ = try await LeoSurfacedFileDownloader(transport: transport).download(id: "", to: directory.appending(path: "x"), maxBytes: 1)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func httpsTransportSendsTheRangeHeaderToThePairedOrigin() throws {
        let transport = LeoHTTPSTransport(endpoint: LeoRemoteEndpoint(baseURL: URL(string: "https://leo.example.com")!, token: "tok"))
        let request = try transport.urlRequest(for: LeoFileRequest(method: "GET", path: "/api/v1/files/f1", range: 4...7), timeout: 5)
        #expect(request.url?.absoluteString == "https://leo.example.com/api/v1/files/f1")
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=4-7")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }
}

/// Serves one file the way Go's `http.ServeContent` does (HEAD, Range →
/// 206 with Content-Range), or 404 once evicted.
final class FakeFileTransport: LeoFileTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let content: Data?
    private let status: Int?
    private let contentType: String?
    private let evictAfterRequests: Int?
    private var recorded: [LeoFileRequest] = []

    init(content: Data?, status: Int? = nil, contentType: String? = nil, evictAfterRequests: Int? = nil) {
        self.content = content
        self.status = status
        self.contentType = contentType
        self.evictAfterRequests = evictAfterRequests
    }

    var requests: [LeoFileRequest] { lock.withLock { recorded } }

    func fetch(_ request: LeoFileRequest, timeout: TimeInterval) async throws -> LeoFileResponse {
        let count = lock.withLock {
            recorded.append(request)
            return recorded.count
        }
        if let status { return LeoFileResponse(status: status, headers: [:], body: Data()) }
        guard let content, count <= (evictAfterRequests ?? .max) else {
            return LeoFileResponse(status: 404, headers: [:], body: Data(#"{"ok":false}"#.utf8))
        }
        var headers = ["content-length": "\(content.count)", "accept-ranges": "bytes"]
        if let contentType { headers["content-type"] = contentType }
        if request.method == "HEAD" { return LeoFileResponse(status: 200, headers: headers, body: Data()) }
        guard let range = request.range else { return LeoFileResponse(status: 200, headers: headers, body: content) }
        let upper = min(Int(range.upperBound), content.count - 1)
        let slice = content[Int(range.lowerBound)...upper]
        headers["content-length"] = "\(slice.count)"
        headers["content-range"] = "bytes \(range.lowerBound)-\(upper)/\(content.count)"
        return LeoFileResponse(status: 206, headers: headers, body: Data(slice))
    }
}
