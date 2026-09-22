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

    /// Nil at end of file. May return fewer bytes than asked for.
    func read(_ handle: Data, offset: UInt64, length: UInt32, path: String) async throws -> Data? {
        let response = try await transport.send(.read(handle: handle, offset: offset, length: length))
        if case let .data(data) = response { return data }
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
            return .protocolError("expected \(expected), got \(Self.name(of: response))")
        }
        return Self.error(for: status, path: path)
    }

    static func error(for status: LeoSFTPStatus, path: String) -> LeoFileAccessError {
        switch status.code {
        case .noSuchFile: .notFound(path: path)
        case .permissionDenied: .permissionDenied(path: path)
        case .noConnection, .connectionLost: .disconnected
        case .unsupported: .protocolError("the server doesn’t support this operation")
        case .ok, .eof: .protocolError("unexpected status \(status.message.isEmpty ? String(describing: status.code) : status.message)")
        case .failure, .badMessage, .other: .failed(path: path, reason: status.message.isEmpty ? "the server reported a failure" : status.message)
        }
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
