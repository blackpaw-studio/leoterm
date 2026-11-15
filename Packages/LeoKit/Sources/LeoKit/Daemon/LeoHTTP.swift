import Foundation

public struct LeoHTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let body: Data?
    /// The body's media type; nil means JSON.
    public let contentType: String?
    /// Extra request headers, such as `If-Match`. Names and values are
    /// checked when the request is built (`validatedHeaders()`).
    public let headers: [String: String]

    public init(method: String, path: String, body: Data? = nil, contentType: String? = nil, headers: [String: String] = [:]) {
        self.method = method
        self.path = path
        self.body = body
        self.contentType = contentType
        self.headers = headers
    }

    /// The headers in a stable order. Throws on a name that isn't an HTTP
    /// token or a value with a control character, so a revision or other
    /// caller-supplied string can never split the request.
    public func validatedHeaders() throws -> [(name: String, value: String)] {
        try headers.sorted { $0.key < $1.key }.map { name, value in
            guard Self.isToken(name) else { throw LeoDaemonError.decoding("Invalid HTTP header name \(name.debugDescription)") }
            guard !value.unicodeScalars.contains(where: Self.isControl) else {
                throw LeoDaemonError.decoding("Invalid value for HTTP header \(name)")
            }
            return (name, value)
        }
    }

    public func serialized() throws -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if let body {
            head += "Content-Type: \(contentType ?? "application/json")\r\nContent-Length: \(body.count)\r\n"
        }
        for (name, value) in try validatedHeaders() { head += "\(name): \(value)\r\n" }
        var result = Data((head + "\r\n").utf8)
        if let body { result.append(body) }
        return result
    }

    private static let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
        .union(CharacterSet(charactersIn: "a"..."z")).union(CharacterSet(charactersIn: "A"..."Z"))
        .union(CharacterSet(charactersIn: "0"..."9"))

    private static func isToken(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy(tokenCharacters.contains)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 && scalar != "\t" || scalar.value == 0x7F
    }
}

public struct LeoHTTPResponse: Equatable, Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public static func parse(_ data: Data) throws -> Self {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else {
            throw LeoDaemonError.decoding("HTTP response has no header terminator")
        }
        let headerData = data[..<range.lowerBound]
        guard let headers = String(data: headerData, encoding: .utf8),
              let statusLine = headers.components(separatedBy: "\r\n").first else {
            throw LeoDaemonError.decoding("HTTP response headers are not UTF-8")
        }
        let components = statusLine.split(separator: " ")
        guard components.count > 1, components[0].hasPrefix("HTTP/"), let status = Int(components[1]) else {
            throw LeoDaemonError.decoding("Invalid HTTP status line")
        }
        let rawBody = Data(data[range.upperBound...])
        let fields = Dictionary(uniqueKeysWithValues: headers
            .components(separatedBy: "\r\n")
            .dropFirst()
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (parts[0].lowercased(), parts[1].trimmingCharacters(in: .whitespaces))
            })
        if fields["transfer-encoding"]?.lowercased() == "chunked" {
            return Self(status: status, body: try decodeChunked(rawBody))
        }
        if let contentLength = fields["content-length"],
           let expected = Int(contentLength), rawBody.count < expected {
            throw LeoDaemonError.decoding("Truncated HTTP body")
        }
        return Self(status: status, body: rawBody)
    }

    private static func decodeChunked(_ data: Data) throws -> Data {
        var output = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while index < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex),
                  let line = String(data: data[index..<lineEnd.lowerBound], encoding: .utf8),
                  let size = Int(line.split(separator: ";")[0], radix: 16) else {
                throw LeoDaemonError.decoding("Invalid chunked HTTP body")
            }
            index = lineEnd.upperBound
            if size == 0 { return output }
            guard let end = data.index(index, offsetBy: size, limitedBy: data.endIndex), end <= data.endIndex else {
                throw LeoDaemonError.decoding("Truncated chunked HTTP body")
            }
            output.append(data[index..<end])
            guard data[end...].starts(with: crlf) else {
                throw LeoDaemonError.decoding("Chunk missing terminator")
            }
            index = data.index(end, offsetBy: crlf.count)
        }
        throw LeoDaemonError.decoding("Chunked HTTP body lacks final chunk")
    }
}
