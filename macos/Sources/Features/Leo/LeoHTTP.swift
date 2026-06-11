import Foundation

/// A minimal HTTP/1.1 request to the daemon socket. We always close the
/// connection per-request (`Connection: close`) so the response terminates at EOF.
struct LeoHTTPRequest {
    let method: String
    let path: String
    var body: Data?

    func serialized() -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: localhost\r\n"
        head += "Connection: close\r\n"
        if let body {
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }
}

/// A parsed HTTP/1.1 response. Only the status line and body are needed.
struct LeoHTTPResponse {
    let status: Int
    let body: Data

    /// Parse raw response bytes. Throws `LeoError.decode` on a malformed head.
    /// Handles both `Content-Length` and `Transfer-Encoding: chunked` bodies.
    static func parse(_ raw: Data) throws(LeoError) -> LeoHTTPResponse {
        // Split head/body on the first CRLFCRLF.
        let sep = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: sep) else {
            throw LeoError.decode(detail: "no header terminator in response")
        }
        let head = raw[raw.startIndex..<range.lowerBound]
        let rawBody = raw[range.upperBound...]
        guard let headText = String(data: head, encoding: .utf8),
              let statusLine = headText.components(separatedBy: "\r\n").first else {
            throw LeoError.decode(detail: "unreadable response head")
        }
        // "HTTP/1.1 200 OK"
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
            throw LeoError.decode(detail: "bad status line: \(statusLine)")
        }

        // Detect chunked transfer encoding in headers.
        let isChunked = headText.components(separatedBy: "\r\n").contains { line in
            line.lowercased().hasPrefix("transfer-encoding:") && line.lowercased().contains("chunked")
        }

        let body: Data
        if isChunked {
            body = try unchunk(Data(rawBody))
        } else {
            body = Data(rawBody)
        }
        return LeoHTTPResponse(status: code, body: body)
    }

    /// Decode an HTTP/1.1 chunked-encoded body into the raw payload bytes.
    private static func unchunk(_ data: Data) throws(LeoError) -> Data {
        var result = Data()
        var pos = data.startIndex
        let crlf = Data("\r\n".utf8)

        while pos < data.endIndex {
            // Read the chunk-size line (hex digits, optional extensions, then CRLF).
            guard let lineEnd = data.range(of: crlf, in: pos..<data.endIndex) else {
                throw LeoError.decode(detail: "chunked: missing CRLF after chunk size")
            }
            let sizeSlice = data[pos..<lineEnd.lowerBound]
            guard let sizeStr = String(data: sizeSlice, encoding: .utf8),
                  let chunkSize = Int(sizeStr.split(separator: ";")[0]
                                         .trimmingCharacters(in: CharacterSet.whitespaces),
                                     radix: 16) else {
                throw LeoError.decode(detail: "chunked: bad chunk size")
            }
            pos = lineEnd.upperBound
            if chunkSize == 0 { break } // Last chunk.
            let chunkEnd = data.index(pos, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            result.append(data[pos..<chunkEnd])
            pos = chunkEnd
            // Skip the trailing CRLF after the chunk data.
            if data[pos...].starts(with: crlf) {
                pos = data.index(pos, offsetBy: crlf.count)
            }
        }
        return result
    }
}
