import Foundation

/// Typed SFTP v3 operations over a handshaken `LeoSFTPTransport`. Each call
/// is one request/reply; a failure status becomes a `LeoFileAccessError`
/// about `path`, so callers can surface it as is.
struct LeoSFTPClient: Sendable {
    let transport: LeoSFTPTransport
    let server: LeoSFTPServerVersion

    func stat(_ path: String) async throws -> LeoSFTPAttributes {
        try attributes(from: try await transport.send(.stat(path: path)), path: path)
    }

    func lstat(_ path: String) async throws -> LeoSFTPAttributes {
        try attributes(from: try await transport.send(.lstat(path: path)), path: path)
    }

    func realpath(_ path: String) async throws -> String {
        let response = try await transport.send(.realpath(path: path))
        guard case let .names(names) = response, let first = names.first else {
            throw unexpected(response, expected: "NAME", path: path)
        }
        return first.filename
    }

    func open(_ path: String, flags: LeoSFTPOpenFlags, attributes: LeoSFTPAttributes = .init()) async throws -> Data {
        try handle(from: try await transport.send(.open(path: path, flags: flags, attributes: attributes)), path: path)
    }

    func openDirectory(_ path: String) async throws -> Data {
        try handle(from: try await transport.send(.opendir(path: path)), path: path)
    }

    func close(_ handle: Data, path: String) async throws {
        try expectOK(try await transport.send(.close(handle: handle)), path: path)
    }

    /// Nil at end of file. May return fewer bytes than asked for, never
    /// more: a longer reply is a protocol error, since the extra bytes would
    /// be stitched into the file at the wrong offset.
    func read(_ handle: Data, offset: UInt64, length: UInt32, path: String) async throws -> Data? {
        let response = try await transport.send(.read(handle: handle, offset: offset, length: length))
        if case let .data(data) = response {
            guard data.count <= Int(length) else {
                throw LeoFileAccessError.protocolError("a \(length)-byte read returned \(data.count) bytes")
            }
            return data
        }
        if case .status(let status) = response, status.code == .eof { return nil }
        throw unexpected(response, expected: "DATA", path: path)
    }

    func write(_ handle: Data, offset: UInt64, data: Data, path: String) async throws {
        try expectOK(try await transport.send(.write(handle: handle, offset: offset, data: data)), path: path)
    }

    func setAttributes(_ handle: Data, _ attributes: LeoSFTPAttributes, path: String) async throws {
        try expectOK(try await transport.send(.fsetstat(handle: handle, attributes: attributes)), path: path)
    }

    /// Nil once the directory is exhausted.
    func readDirectory(_ handle: Data, path: String) async throws -> [LeoSFTPName]? {
        let response = try await transport.send(.readdir(handle: handle))
        if case let .names(names) = response { return names }
        if case .status(let status) = response, status.code == .eof { return nil }
        throw unexpected(response, expected: "NAME", path: path)
    }

    func remove(_ path: String) async throws {
        try expectOK(try await transport.send(.remove(path: path)), path: path)
    }

    /// Plain v3 RENAME: OpenSSH refuses to replace an existing `destination`.
    func rename(_ source: String, to destination: String) async throws {
        try expectOK(try await transport.send(.rename(from: source, to: destination)), path: destination)
    }

    /// `posix-rename@openssh.com`: rename(2), atomically replacing `destination`.
    func posixRename(_ source: String, to destination: String) async throws {
        try expectOK(try await transport.send(.posixRename(from: source, to: destination)), path: destination)
    }

    // MARK: - Reply handling

    private func expectOK(_ response: LeoSFTPResponse, path: String) throws {
        guard case .status(let status) = response, status.code == .ok else {
            throw unexpected(response, expected: "STATUS", path: path)
        }
    }

    private func handle(from response: LeoSFTPResponse, path: String) throws -> Data {
        guard case let .handle(handle) = response else { throw unexpected(response, expected: "HANDLE", path: path) }
        return handle
    }

    private func attributes(from response: LeoSFTPResponse, path: String) throws -> LeoSFTPAttributes {
        guard case let .attributes(attributes) = response else { throw unexpected(response, expected: "ATTRS", path: path) }
        return attributes
    }

    /// The error for a reply that isn't the success the caller wanted: a
    /// failure status maps to its `LeoFileAccessError`; anything else is a
    /// protocol violation.
    private func unexpected(_ response: LeoSFTPResponse, expected: String, path: String) -> LeoFileAccessError {
        guard case .status(let status) = response else {
            return .protocolError("expected \(verbatim: expected), got \(verbatim: Self.name(of: response))")
        }
        return Self.error(for: status, path: path)
    }

    /// As specific as v3 allows. A server's own message is quoted, as
    /// strerror is locally -- sanitized and attributed to the server (see
    /// `LeoSFTPServerText`) -- unless it is just the code's name, which is
    /// all OpenSSH ever sends ("Failure"), and which gets a sentence here.
    static func error(for status: LeoSFTPStatus, path: String) -> LeoFileAccessError {
        let message = explanation(status.message)
        switch status.code {
        case .noSuchFile: return .notFound(path: path)
        case .permissionDenied: return .permissionDenied(path: path)
        case .noConnection, .connectionLost: return .disconnected
        case .ok, .eof:
            let detail: LeoFileAccessReason = "unexpected status \(verbatim: "\(status.code)")"
            return .protocolError(message.map { detail + "; " + $0 } ?? detail)
        case .failure: return .failed(path: path, reason: message ?? "the server couldn’t complete the operation and gave no reason")
        case .unsupported: return .failed(path: path, reason: message ?? "the server doesn’t support this operation")
        case .other(let code): return .failed(path: path, reason: message ?? "the server reported error \(code)")
        case .badMessage:
            // OpenSSH's sftp-server answers ENAMETOOLONG with BAD_MESSAGE.
            let reason: LeoFileAccessReason = isNameTooLong(path) ? "File name too long" : "the server rejected the request as malformed"
            return .failed(path: path, reason: message ?? reason)
        }
    }

    /// The server's message without surrounding whitespace or a trailing
    /// period, quoted as the server's; nil when it shows as nothing or
    /// only restates a status code's name. Every path that shows server
    /// text goes through here; it is cleaned when rendered.
    private static func explanation(_ message: String) -> LeoFileAccessReason? {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".") { text.removeLast() }
        let shown = LeoSFTPServerText.sanitized(text)
        guard !shown.isEmpty, !statusNames.contains(shown.lowercased()) else { return nil }
        return LeoSFTPServerText.quoted(text)
    }

    /// OpenSSH's `status_to_message` texts.
    private static let statusNames: Set<String> = [
        "success", "end of file", "no such file", "permission denied", "failure",
        "bad message", "no connection", "connection lost", "operation unsupported", "unknown error",
    ]

    /// A component over NAME_MAX or a path over PATH_MAX (macOS: 255/1024).
    private static func isNameTooLong(_ path: String) -> Bool {
        path.utf8.count >= Int(PATH_MAX) || path.split(separator: "/").contains { $0.utf8.count > Int(NAME_MAX) }
    }

    private static func name(of response: LeoSFTPResponse) -> String {
        switch response {
        case .status: "STATUS"
        case .handle: "HANDLE"
        case .data: "DATA"
        case .names: "NAME"
        case .attributes: "ATTRS"
        case .extendedReply: "EXTENDED_REPLY"
        }
    }
}
