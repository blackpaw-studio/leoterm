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
    static func parse(_ raw: Data) throws(LeoError) -> LeoHTTPResponse {
        // Split head/body on the first CRLFCRLF.
        let sep = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: sep) else {
            throw LeoError.decode(detail: "no header terminator in response")
        }
        let head = raw[raw.startIndex..<range.lowerBound]
        let body = raw[range.upperBound...]
        guard let headText = String(data: head, encoding: .utf8),
              let statusLine = headText.components(separatedBy: "\r\n").first else {
            throw LeoError.decode(detail: "unreadable response head")
        }
        // "HTTP/1.1 200 OK"
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
            throw LeoError.decode(detail: "bad status line: \(statusLine)")
        }
        return LeoHTTPResponse(status: code, body: Data(body))
    }
}
