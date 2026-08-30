import Foundation
import os

/// Production `LeoDaemon`: HTTP/1.1 over the daemon's unix socket
/// (`~/.leo/state/leo.sock`). The socket's `0600` file permissions are the
/// auth — no token is sent. Templates are not exposed on the socket, so
/// `listTemplates()` shells out to the `leo` CLI.
struct LeoSocketClient: LeoDaemon {
    let socketPath: String
    let leoExecutable: String
    /// The leo host these CLI fallbacks target. `nil`/`localhost` runs the CLI
    /// locally; a remote name adds `--host <name>` so the CLI SSH-dispatches.
    /// Socket calls always use `socketPath` (the local or forwarded socket).
    let host: String?
    private static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "leo-daemon")

    init(socketPath: String = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath,
         host: String? = nil,
         leoExecutable: String = LeoCLI.executablePath) {
        self.socketPath = socketPath
        self.host = host
        self.leoExecutable = leoExecutable
    }

    /// Prepend `--host <name>` to a CLI argument list for a remote host.
    /// A `nil` or `localhost` host runs the CLI locally, unchanged.
    static func cliArgs(host: String?, _ args: [String]) -> [String] {
        guard let host, host != LeoHost.localhostName else { return args }
        return ["--host", host] + args
    }

    // MARK: LeoDaemon

    func listAgents() async throws(LeoError) -> [Agent] {
        let body = try await request(.init(method: "GET", path: "/agents/list"))
        // Per-record tolerant: one malformed agent shouldn't take down the roster.
        return try Agent.decodeRoster(from: body)
    }

    func spawn(_ req: AgentSpawnRequest) async throws(LeoError) -> Agent {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(req)
        } catch {
            throw LeoError.decode(detail: "encode spawn: \(error)")
        }
        let body = try await request(.init(method: "POST", path: "/agents/spawn", body: payload))
        return try LeoEnvelope<Agent>.decode(body).value()
    }

    func stop(name: String) async throws(LeoError) {
        let segment = try Self.pathSegment(for: name)
        let body = try await request(.init(method: "POST", path: "/agents/\(segment)/stop"))
        try LeoEnvelope<EmptyData>.decode(body).expectOK()
    }

    /// Delete an agent. leo v0.19 replaced `POST /agents/<name>/prune` with
    /// `DELETE /agents/{name}`; the method name is kept (rather than renamed
    /// to `delete`) so `LeoAgentStore`'s public API is unaffected.
    func prune(name: String) async throws(LeoError) {
        let segment = try Self.pathSegment(for: name)
        let body = try await request(.init(method: "DELETE", path: "/agents/\(segment)"))
        try LeoEnvelope<EmptyData>.decode(body).expectOK()
    }

    func listTemplates() async throws(LeoError) -> [Template] {
        let out = try runCLI(["template", "list", "--json"])
        do {
            return try JSONDecoder().decode([Template].self, from: out)
        } catch {
            throw LeoError.decode(detail: "template list: \(error)")
        }
    }

    // MARK: - Transport

    /// `{}` placeholder for endpoints whose `data` we ignore.
    private struct EmptyData: Decodable {}

    /// Characters allowed unescaped in a path segment. Deliberately excludes
    /// `/` (unlike `.urlPathAllowed`, which does not escape it) so a name
    /// containing a path separator can never smuggle extra path components
    /// into the request (e.g. `a/../b/stop`).
    private static let pathSafeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    private static let validAgentNameCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )

    /// Validate an agent name against `^[A-Za-z0-9._-]+$` and percent-encode
    /// it for use as a single URL path segment. Rejects empty names and any
    /// name containing `/` or other characters that could alter the request
    /// path before a request is ever built.
    static func pathSegment(for name: String) throws(LeoError) -> String {
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ validAgentNameCharacters.contains($0) }) else {
            throw LeoError.invalidAgentName(name)
        }
        return name.addingPercentEncoding(withAllowedCharacters: pathSafeCharacters) ?? name
    }

    /// Send one request over a fresh POSIX unix-domain socket connection and
    /// return the response body. Opens, writes, reads until EOF, then closes.
    private func request(_ req: LeoHTTPRequest) async throws(LeoError) -> Data {
        let path = socketPath
        let wire = req.serialized()
        // Run blocking I/O on a background thread to avoid stalling the cooperative thread pool.
        // The continuation throws generic Error; map to LeoError after the await.
        let result: Result<Data, LeoError> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data = try Self.sendRequest(socketPath: path, wire: wire)
                    continuation.resume(returning: .success(data))
                } catch let e as LeoError {
                    continuation.resume(returning: .failure(e))
                } catch {
                    continuation.resume(returning: .failure(LeoError.daemonUnreachable))
                }
            }
        }
        switch result {
        case .success(let data): return data
        case .failure(let e): throw e
        }
    }

    /// Blocking POSIX unix-domain socket round-trip. Runs on a background queue.
    private static func sendRequest(socketPath: String, wire: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LeoError.daemonUnreachable }
        defer { close(fd) }

        // FIX 1: Prevent SIGPIPE when writing to a peer-closed socket.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // FIX 2: 5-second send/receive timeout so a hung daemon can't block forever.
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Build sockaddr_un from the path.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard socketPath.utf8.count <= maxLen else { throw LeoError.daemonUnreachable }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                _ = strncpy(UnsafeMutableRawPointer(ptr).bindMemory(to: CChar.self, capacity: maxLen + 1), src, maxLen)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw LeoError.daemonUnreachable }

        // FIX 3: Full write loop — keep sending until all bytes are flushed.
        var totalSent = 0
        while totalSent < wire.count {
            let sent = wire.withUnsafeBytes { buf in
                Darwin.send(fd, buf.baseAddress!.advanced(by: totalSent), wire.count - totalSent, 0)
            }
            if sent <= 0 { throw LeoError.daemonUnreachable }
            totalSent += sent
        }

        // Shutdown write half so the server sees EOF and closes after responding.
        Darwin.shutdown(fd, SHUT_WR)

        // Read response until EOF.
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n < 0 { throw LeoError.daemonUnreachable }
            if n == 0 { break }
            received.append(contentsOf: chunk[0..<n])
        }

        let resp = try LeoHTTPResponse.parse(received)
        guard (200..<300).contains(resp.status) else {
            let envelope = try? LeoEnvelope<EmptyData>.decode(resp.body)
            throw LeoError.daemon(message: envelope?.error ?? "HTTP \(resp.status)", code: envelope?.code)
        }
        return resp.body
    }

    /// Run the `leo` CLI and return stdout. Used only for templates.
    /// `args` are host-routed via `cliArgs` before launch.
    private func runCLI(_ args: [String]) throws(LeoError) -> Data {
        try LeoProcessRunner.run(executable: leoExecutable, args: Self.cliArgs(host: host, args))
    }
}
