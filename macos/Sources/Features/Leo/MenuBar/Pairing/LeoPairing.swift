import Foundation
import LeoKit
import OSLog

/// What `leo pair --json` prints (leo ≥ 0.57.0): the flat pairing fields.
/// `qrPayload` is encoded into the QR verbatim; `expiresAt` is when the code stops working.
struct LeoPairingPayload: Equatable, Sendable {
    let daemonID: String
    let name: String
    let urls: [String]
    let pairingCode: String
    let warnings: [String]
    let expiresAt: Date
    let qrPayload: String
}

extension LeoPairingPayload: Decodable {
    private enum CodingKeys: String, CodingKey {
        case daemonID = "daemon_id", name, urls, pairingCode = "pairing_code", warnings
        case expiresAt = "expires_at", qrPayload = "qr_payload"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let expiry = try container.decode(String.self, forKey: .expiresAt)
        guard let expiresAt = LeoRFC3339.date(from: expiry) else {
            throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: container, debugDescription: "not RFC3339: \(expiry)")
        }
        self.init(
            daemonID: try container.decode(String.self, forKey: .daemonID),
            name: try container.decode(String.self, forKey: .name),
            urls: try container.decode([String].self, forKey: .urls),
            pairingCode: try container.decode(String.self, forKey: .pairingCode),
            warnings: try container.decodeIfPresent([String].self, forKey: .warnings) ?? [],
            expiresAt: expiresAt,
            qrPayload: try container.decode(String.self, forKey: .qrPayload)
        )
    }
}

/// `leo web enable --json` → `{ok, changed, restarted, web:{…}}`. `restarted`
/// means the daemon bounced, so pairing has to wait for it to come back.
struct LeoWebEnableResult: Equatable, Sendable {
    let changed: Bool
    let restarted: Bool
}

/// A failed `leo pair` / `leo web enable`. Every `--json` failure is
/// `{error, message?}` with a non-zero exit and only JSON on stdout.
enum LeoPairingError: Error, Equatable {
    /// The web listener is off, so there is nothing to pair against.
    case webDisabled(message: String?)
    /// Any other stable leo error code.
    case leo(code: String, message: String?)
    /// leo failed without usable JSON (an older leo, a crash): its stderr, or the exit status.
    case unreadable(String)
    /// leo could not be run at all.
    case unavailable(String)
    /// leo handed back a code that had already expired.
    case expired

    /// The sentence shown to the user.
    var message: String {
        switch self {
        case .webDisabled: "Web access is turned off."
        case let .leo(code, message): message.flatMap { $0.isEmpty ? nil : $0 } ?? "leo reported \(code)."
        case let .unreadable(message), let .unavailable(message): message
        case .expired: "leo returned a pairing code that has already expired. Check that this Mac’s date and time are correct."
        }
    }
}

/// Runs `leo pair` and `leo web enable` through the shared `LeoCLI` seam.
struct LeoPairingService: Sendable {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")
    static let timeout: TimeInterval = 30
    /// `web enable` restarts the daemon gracefully, which drains busy agents for up to 10 minutes.
    static let enableTimeout: TimeInterval = LeoDaemonRestarter.timeout
    static let webDisabledCode = "web_disabled"
    /// Where the daemon's own log lives; the generic failure message points users there.
    static let logHint = "See ~/.leo/state/service.log."

    let cli: LeoCLI

    func pair() async throws -> LeoPairingPayload {
        try decode(LeoPairingPayload.self, from: try await run(["pair", "--json"], failure: "Pairing failed", timeout: Self.timeout))
    }

    func enableWeb(bind: String? = nil, allowHosts: [String] = []) async throws -> LeoWebEnableResult {
        let arguments = ["web", "enable"]
            + (bind.map { ["--bind", $0] } ?? [])
            + allowHosts.flatMap { ["--allow-host", $0] }
            + ["--json"]
        let reply = try decode(WebEnableReply.self, from: try await run(arguments, failure: "Enabling web access failed", timeout: Self.enableTimeout))
        guard reply.ok else { throw LeoPairingError.unreadable("leo could not enable web access.") }
        return LeoWebEnableResult(changed: reply.changed, restarted: reply.restarted)
    }

    private struct WebEnableReply: Decodable {
        let ok: Bool
        let changed: Bool
        let restarted: Bool
    }

    private struct ErrorReply: Decodable {
        let error: String
        let message: String?
    }

    /// The bundled `Contents/Helpers/leo` by explicit path (D6): the version that ships with this
    /// app speaks `pair --json`, which an older `leo` on `PATH` or in the marker may not. An
    /// explicit executable setting still wins, and a build without the helper falls back to the
    /// usual lookup.
    private func resolveExecutable() throws -> String {
        if cli.executableOverride == nil, let bundled = cli.bundledExecutable, cli.isExecutable(bundled) { return bundled }
        return try cli.resolveExecutable()
    }

    /// stdout on success; maps every failure shape to a `LeoPairingError`. `failure` leads the
    /// generic message for a failure without JSON: raw stderr goes to the log, never to the panel.
    private func run(_ arguments: [String], failure: String, timeout: TimeInterval) async throws -> Data {
        let result: LeoProcessResult
        do {
            result = try await cli.runner.run(executable: try resolveExecutable(), arguments: arguments, timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch let LeoDaemonError.transport(message) {
            throw LeoPairingError.unavailable(message)
        } catch {
            throw LeoPairingError.unavailable(error.localizedDescription)
        }
        if let reply = try? JSONDecoder().decode(ErrorReply.self, from: result.stdout) {
            throw reply.error == Self.webDisabledCode
                ? LeoPairingError.webDisabled(message: reply.message)
                : LeoPairingError.leo(code: reply.error, message: reply.message)
        }
        guard result.status == 0 else {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            Self.logger.error("leo \(arguments.first ?? "", privacy: .public) exited \(result.status): \(stderr, privacy: .private)")
            throw LeoPairingError.unreadable("\(failure) (leo exited \(result.status)). \(Self.logHint)")
        }
        return result.stdout
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LeoPairingError.unreadable("Couldn’t read leo’s reply: \(error.localizedDescription)")
        }
    }
}

enum LeoRFC3339 {
    /// RFC3339 with or without fractional seconds. Formatters are built per call: they aren't `Sendable`.
    static func date(from string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }
}
