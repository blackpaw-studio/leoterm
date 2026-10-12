import Foundation

/// One file for `POST /api/v1/chat/uploads` (multipart, field `file`, one
/// file, 50 MB cap). The daemon files audio as a voice note.
public struct LeoChatUpload: Equatable, Sendable {
    public static let maximumBytes = 50 * 1024 * 1024

    public enum Failure: Error, Equatable, Sendable {
        case tooLarge(bytes: Int, limit: Int)
    }

    public let filename: String
    public let mime: String
    public let data: Data

    public init(filename: String, mime: String, data: Data) {
        self.filename = filename
        self.mime = mime
        self.data = data
    }

    public func validated(maximumBytes: Int = Self.maximumBytes) -> Result<Void, Failure> {
        data.count > maximumBytes ? .failure(.tooLarge(bytes: data.count, limit: maximumBytes)) : .success(())
    }

    public static func contentType(boundary: String) -> String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public func multipartBody(boundary: String) -> Data {
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(Self.quoted(filename))\"\r\n".utf8))
        body.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// Escapes what would end the quoted filename or the header line (the
    /// HTML form encoding: `"` → `%22`, CR/LF → `%0D`/`%0A`).
    private static func quoted(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
}

extension LeoChatUpload.Failure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes, let limit):
            let formatter = ByteCountFormatter()
            return String(localized: "\(formatter.string(fromByteCount: Int64(bytes))) is over the \(formatter.string(fromByteCount: Int64(limit))) upload limit.")
        }
    }
}
