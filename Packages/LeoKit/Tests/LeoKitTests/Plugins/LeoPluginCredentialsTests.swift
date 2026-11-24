import Foundation
import Testing

@testable import LeoKit

/// Records every Keychain read; answers from a table. No real Keychain.
private final class FakeCredentialKeychain: LeoPluginCredentialKeychain, @unchecked Sendable {
    struct Read: Equatable {
        let service: String
        let account: String
        let allowUI: Bool
    }

    private let lock = NSLock()
    private var answers: [String: Result<Data, LeoPluginCredentialKeychainError>] = [:]
    private var _reads: [Read] = []
    var reads: [Read] { lock.withLock { _reads } }

    func answer(_ service: String, _ result: Result<Data, LeoPluginCredentialKeychainError>) {
        lock.withLock { answers[service] = result }
    }

    func password(service: String, account: String, allowUI: Bool) throws -> Data {
        try lock.withLock {
            _reads.append(Read(service: service, account: account, allowUI: allowUI))
            return try (answers[service] ?? .failure(.notFound)).get()
        }
    }
}

private struct FakeFiles: LeoPluginCredentialFileReading {
    var files: [String: Data] = [:]
    func read(path: String, maxBytes: Int) throws -> Data {
        guard let data = files[path] else { throw LeoPluginCredentialError.notFound }
        guard data.count <= maxBytes else { throw LeoPluginCredentialError.invalid }
        return data
    }
}

private let home = "/Users/evan"
private let token = "sk-ant-oat01-SECRET-TOKEN"

private func claudeJSON(_ accessToken: String = token) -> Data {
    Data(#"{"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"r","expiresAt":1}}"#.utf8)
}

private func credentials(keychain: FakeCredentialKeychain = FakeCredentialKeychain(), files: FakeFiles = FakeFiles()) -> LeoPluginCredentials {
    LeoPluginCredentials(keychain: keychain, files: files, home: home, userName: "evan")
}

private func grant(_ kind: LeoPluginCredentialKind, _ path: String) -> LeoPluginCredentialGrant {
    LeoPluginCredentialGrant(id: "g1", kind: kind, path: path)
}

struct LeoPluginCredentialsTests {
    // MARK: Service names

    @Test func theDefaultClaudeDirUsesTheBareServiceName() {
        #expect(LeoPluginCredentials.claudeServiceName(configDir: "/Users/evan/.claude", home: home) == "Claude Code-credentials")
    }

    /// Vectors verified on this Mac against Claude Code's own Keychain items (2026-11-21).
    @Test(arguments: [
        ("/Users/evan/.claude-blackpaw-leo", "Claude Code-credentials-4d74f2ae"),
        ("/Users/evan/.claude-jackie", "Claude Code-credentials-1d81f9af"),
        ("/Users/evan/.claude-blackpaw-evan", "Claude Code-credentials-429abf25"),
    ])
    func aCustomDirHashesItsAbsolutePath(_ dir: String, _ service: String) {
        #expect(LeoPluginCredentials.claudeServiceName(configDir: dir, home: home) == service)
    }

    @Test func aTrailingSlashAndTildeNameTheSameItem() {
        let expected = "Claude Code-credentials-4d74f2ae"
        #expect(LeoPluginCredentials.claudeServiceName(configDir: "/Users/evan/.claude-blackpaw-leo/", home: home) == expected)
        #expect(LeoPluginCredentials.claudeServiceName(configDir: "~/.claude-blackpaw-leo", home: home) == expected)
        #expect(LeoPluginCredentials.claudeServiceName(configDir: "~/.claude/", home: home) == "Claude Code-credentials")
    }

    // MARK: Claude

    @Test func aClaudeTokenFromTheKeychainBecomesTheBoundHeaders() throws {
        let keychain = FakeCredentialKeychain()
        keychain.answer("Claude Code-credentials-4d74f2ae", .success(claudeJSON()))
        let credential = try credentials(keychain: keychain).resolve(grant(.claudeCode, "/Users/evan/.claude-blackpaw-leo"), allowUI: false)
        #expect(credential.boundHost == "api.anthropic.com")
        #expect(credential.headers == [
            "Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-cli/2.1.0 (external, cli)",
        ])
        #expect(keychain.reads == [.init(service: "Claude Code-credentials-4d74f2ae", account: "evan", allowUI: false)])
    }

    @Test func aKeychainMissFallsBackToTheCredentialsFile() throws {
        let files = FakeFiles(files: ["/Users/evan/.claude-x/.credentials.json": claudeJSON("file-token")])
        let credential = try credentials(files: files).resolve(grant(.claudeCode, "/Users/evan/.claude-x"), allowUI: false)
        #expect(credential.headers["Authorization"] == "Bearer file-token")
    }

    @Test func aMissingClaudeTokenIsNotFound() {
        #expect(throws: LeoPluginCredentialError.notFound) {
            try credentials().resolve(grant(.claudeCode, "/Users/evan/.claude-x"), allowUI: false)
        }
    }

    @Test(arguments: [#"not json"#, #"{"claudeAiOauth":{}}"#, #"{"claudeAiOauth":{"accessToken":""}}"#, #"{"claudeAiOauth":{"accessToken":"a\r\nX-Evil: 1"}}"#])
    func malformedClaudeCredentialsAreInvalid(_ body: String) {
        let keychain = FakeCredentialKeychain()
        keychain.answer("Claude Code-credentials", .success(Data(body.utf8)))
        #expect(throws: LeoPluginCredentialError.invalid) {
            try credentials(keychain: keychain).resolve(grant(.claudeCode, "/Users/evan/.claude"), allowUI: true)
        }
    }

    @Test func aKeychainReadThatNeedsUIIsSurfacedAndDoesNotFallBack() {
        let keychain = FakeCredentialKeychain()
        keychain.answer("Claude Code-credentials", .failure(.needsAuthorization))
        let files = FakeFiles(files: ["/Users/evan/.claude/.credentials.json": claudeJSON("stale")])
        #expect(throws: LeoPluginCredentialError.needsAuthorization) {
            try credentials(keychain: keychain, files: files).resolve(grant(.claudeCode, "/Users/evan/.claude"), allowUI: false)
        }
    }

    @Test func allowUIIsPassedThroughToTheKeychain() throws {
        let keychain = FakeCredentialKeychain()
        keychain.answer("Claude Code-credentials", .success(claudeJSON()))
        _ = try credentials(keychain: keychain).resolve(grant(.claudeCode, "/Users/evan/.claude"), allowUI: true)
        _ = try credentials(keychain: keychain).resolve(grant(.claudeCode, "/Users/evan/.claude"), allowUI: false)
        #expect(keychain.reads.map(\.allowUI) == [true, false])
    }

    // MARK: Codex

    @Test func codexReadsTheAccessTokenAndAccountID() throws {
        let auth = #"{"OPENAI_API_KEY":null,"tokens":{"access_token":"codex-token","account_id":"acct-123","refresh_token":"r"}}"#
        let files = FakeFiles(files: ["/Users/evan/.codex/auth.json": Data(auth.utf8)])
        let keychain = FakeCredentialKeychain()
        let credential = try credentials(keychain: keychain, files: files).resolve(grant(.codex, "/Users/evan/.codex"), allowUI: false)
        #expect(credential.boundHost == "chatgpt.com")
        #expect(credential.headers == ["Authorization": "Bearer codex-token", "ChatGPT-Account-Id": "acct-123"])
        #expect(credential.headers["User-Agent"] == nil)
        #expect(keychain.reads.isEmpty)
    }

    @Test func codexWithoutTokensIsInvalidAndWithoutAuthJSONIsNotFound() {
        let files = FakeFiles(files: ["/Users/evan/.codex/auth.json": Data(#"{"OPENAI_API_KEY":"sk-x"}"#.utf8)])
        #expect(throws: LeoPluginCredentialError.invalid) {
            try credentials(files: files).resolve(grant(.codex, "/Users/evan/.codex"), allowUI: false)
        }
        #expect(throws: LeoPluginCredentialError.notFound) {
            try credentials().resolve(grant(.codex, "/Users/evan/.codex-other"), allowUI: false)
        }
    }

    @Test func noErrorEverCarriesTheToken() {
        let errors: [LeoPluginCredentialError] = [.notFound, .invalid, .needsAuthorization]
        for error in errors {
            #expect(!"\(error)".contains(token))
            #expect(!error.code.isEmpty)
        }
    }

    // MARK: File reader

    @Test func theFileReaderRefusesAFIFOWithoutBlocking() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("leo-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("auth.json").path
        try #require(mkfifo(fifo, 0o600) == 0)
        #expect(throws: LeoPluginCredentialError.invalid) {
            try LeoPluginCredentialFileReader().read(path: fifo, maxBytes: 1024)
        }
    }

    @Test func theFileReaderReadsARegularFileThroughASymlink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("leo-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.json")
        try Data("{}".utf8).write(to: target)
        let link = dir.appendingPathComponent("auth.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try LeoPluginCredentialFileReader().read(path: link.path, maxBytes: 1024) == Data("{}".utf8))
    }
}
