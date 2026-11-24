import CryptoKit
import Foundation

/// Why an account's token couldn't be read. No case carries token material.
public enum LeoPluginCredentialError: Error, Equatable, Sendable {
    /// Nothing at the account's Keychain item or file.
    case notFound
    /// Present but unreadable: bad JSON, no token, or a token unsafe to send as a header.
    case invalid
    /// The Keychain would need to ask the user (background reads never show UI).
    case needsAuthorization

    /// The bridge's rejection code.
    public var code: String {
        switch self {
        case .notFound, .invalid: "credentialInvalid"
        case .needsAuthorization: "credentialNeedsAuthorization"
        }
    }
}

public enum LeoPluginCredentialKeychainError: Error, Equatable, Sendable {
    case notFound
    case needsAuthorization
}

/// Reads another app's generic-password item. With `allowUI == false` it must
/// never show a dialog: an item that would need one throws `.needsAuthorization`.
/// Read-only by design: there is no write, refresh or delete.
public protocol LeoPluginCredentialKeychain: Sendable {
    func password(service: String, account: String, allowUI: Bool) throws -> Data
}

/// Reads a small file. Throws `LeoPluginCredentialError.notFound` when it is
/// missing and `.invalid` when it is larger than `maxBytes`.
public protocol LeoPluginCredentialFileReading: Sendable {
    func read(path: String, maxBytes: Int) throws -> Data
}

/// The headers to inject into one fetch, and the only host they may go to.
/// App-internal: never encoded onto the bridge, so tokens never reach a plugin.
public struct LeoPluginFetchCredential: Sendable, Equatable {
    public let boundHost: String
    public let headers: [String: String]
}

/// Turns a grant into fetch headers by reading the account's token fresh,
/// every time, from where its CLI keeps it. Never writes or refreshes
/// anything: rotating a token would sign the CLI out.
public struct LeoPluginCredentials: Sendable {
    public static let maxFileBytes = 64 * 1024
    static let claudeService = "Claude Code-credentials"
    static let anthropicBeta = "oauth-2025-04-20"
    /// Claude Code's own identity (the one CodexBar sends). Anthropic's usage
    /// endpoint rate-limits clients that don't look like it.
    static let claudeCodeUserAgent = "claude-cli/2.1.0 (external, cli)"

    private let keychain: any LeoPluginCredentialKeychain
    private let files: any LeoPluginCredentialFileReading
    private let home: String
    private let userName: String

    /// `userName` is the Keychain account Claude Code stores its item under (`$USER`).
    public init(keychain: any LeoPluginCredentialKeychain, files: any LeoPluginCredentialFileReading, home: String, userName: String) {
        self.keychain = keychain
        self.files = files
        self.home = home
        self.userName = userName
    }

    /// Claude Code's Keychain service for a config dir: the bare name for
    /// `~/.claude`, else suffixed with the first 8 hex of sha256 of the
    /// absolute path (no trailing slash). Nil for a relative path.
    public static func claudeServiceName(configDir: String, home: String) -> String? {
        guard let path = LeoPluginCredentialPath.standardize(configDir, home: home) else { return nil }
        if path == LeoPluginCredentialPath.standardize("~/.claude", home: home) { return claudeService }
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(claudeService)-\(digest.prefix(8))"
    }

    /// The headers for `grant`. `allowUI` is true only for reads that follow a
    /// user gesture (adding an account, "Grant access").
    public func resolve(_ grant: LeoPluginCredentialGrant, allowUI: Bool) throws(LeoPluginCredentialError) -> LeoPluginFetchCredential {
        switch grant.kind {
        case .claudeCode:
            let token = try claudeToken(configDir: grant.path, allowUI: allowUI)
            return LeoPluginFetchCredential(
                boundHost: grant.kind.boundHost,
                headers: [
                    "Authorization": "Bearer \(token)", "anthropic-beta": Self.anthropicBeta, "User-Agent": Self.claudeCodeUserAgent,
                ])
        case .codex:
            let auth = try codexAuth(home: grant.path)
            var headers = ["Authorization": "Bearer \(auth.token)"]
            if let account = auth.accountID { headers["ChatGPT-Account-Id"] = account }
            return LeoPluginFetchCredential(boundHost: grant.kind.boundHost, headers: headers)
        }
    }

    // MARK: Claude

    private func claudeToken(configDir: String, allowUI: Bool) throws(LeoPluginCredentialError) -> String {
        guard let service = Self.claudeServiceName(configDir: configDir, home: home) else { throw .invalid }
        let data: Data
        do {
            data = try keychain.password(service: service, account: userName, allowUI: allowUI)
        } catch LeoPluginCredentialKeychainError.needsAuthorization {
            // Not a reason to try the file: a stale file would mask the live token.
            throw .needsAuthorization
        } catch {
            data = try readFile((configDir as NSString).appendingPathComponent(".credentials.json"))
        }
        struct Stored: Decodable {
            struct OAuth: Decodable { let accessToken: String? }
            let claudeAiOauth: OAuth?
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { throw .invalid }
        return try Self.headerSafe(stored.claudeAiOauth?.accessToken)
    }

    // MARK: Codex

    private func codexAuth(home codexHome: String) throws(LeoPluginCredentialError) -> (token: String, accountID: String?) {
        let data = try readFile((codexHome as NSString).appendingPathComponent("auth.json"))
        struct Stored: Decodable {
            struct Tokens: Decodable {
                let access_token: String?
                let account_id: String?
            }
            let tokens: Tokens?
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { throw .invalid }
        let token = try Self.headerSafe(stored.tokens?.access_token)
        let account = try stored.tokens?.account_id.map { value throws(LeoPluginCredentialError) in try Self.headerSafe(value) }
        return (token, account)
    }

    // MARK: Helpers

    private func readFile(_ path: String) throws(LeoPluginCredentialError) -> Data {
        do {
            return try files.read(path: path, maxBytes: Self.maxFileBytes)
        } catch let error as LeoPluginCredentialError {
            throw error
        } catch {
            throw .notFound
        }
    }

    /// A non-empty value of visible ASCII only, so it can't split a header.
    private static func headerSafe(_ value: String?) throws(LeoPluginCredentialError) -> String {
        guard let value, !value.isEmpty, value.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { throw .invalid }
        return value
    }
}

/// Reads credential files from disk, capped so a huge file can't be loaded.
/// Only regular files (a symlink to one is fine): the open is non-blocking and
/// the opened descriptor is checked, so a FIFO or device at the path can't
/// stall the read, and swapping the path after a check doesn't help.
public struct LeoPluginCredentialFileReader: LeoPluginCredentialFileReading {
    public init() {}

    public func read(path: String, maxBytes: Int) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw LeoPluginCredentialError.notFound }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw LeoPluginCredentialError.invalid }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw LeoPluginCredentialError.invalid }
        return data
    }
}
