import Foundation

struct LeoHTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    let body: Data?

    init(method: String, path: String, body: Data? = nil) {
        self.method = method
        self.path = path
        self.body = body
    }

    func serialized() -> Data {
        var headers = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if let body {
            headers += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        var result = Data((headers + "\r\n").utf8)
        if let body { result.append(body) }
        return result
    }
}

struct LeoHTTPResponse: Equatable, Sendable {
    let status: Int
    let body: Data

    static func parse(_ data: Data) throws -> Self {
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
