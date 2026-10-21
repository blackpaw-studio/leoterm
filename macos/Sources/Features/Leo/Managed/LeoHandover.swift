import Foundation

/// `leo service handover … --json` (contract C6): the same shape both ways.
struct LeoHandoverResult: Equatable, Sendable {
    let ok: Bool
    let step: String?
    let error: String?
    let message: String?
    let previousLabel: String?
    /// The CLI daemon's environment, for the marker's `env` (D5).
    let env: [String: String]?
    let plistBackup: String?
    let rolledBack: Bool?
    let managedStopped: Bool?
    let warnings: [String]
}

extension LeoHandoverResult: Decodable {
    private enum CodingKeys: String, CodingKey {
        case ok, step, error, message, env, warnings
        case previousLabel = "previous_label"
        case plistBackup = "plist_backup"
        case rolledBack = "rolled_back"
        case managedStopped = "managed_stopped"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ok: try container.decode(Bool.self, forKey: .ok),
            step: try container.decodeIfPresent(String.self, forKey: .step),
            error: try container.decodeIfPresent(String.self, forKey: .error),
            message: try container.decodeIfPresent(String.self, forKey: .message),
            previousLabel: try container.decodeIfPresent(String.self, forKey: .previousLabel),
            env: try container.decodeIfPresent([String: String].self, forKey: .env),
            plistBackup: try container.decodeIfPresent(String.self, forKey: .plistBackup),
            rolledBack: try container.decodeIfPresent(Bool.self, forKey: .rolledBack),
            managedStopped: try container.decodeIfPresent(Bool.self, forKey: .managedStopped),
            warnings: try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        )
    }
}

enum LeoHandoverRun: Equatable, Sendable {
    case succeeded(LeoHandoverResult)
    case failed(LeoHandoverResult)
    /// Not JSON, or a JSON answer that disagrees with the exit status.
    case malformed(String)
}

/// Runs the handover with the bundled `Contents/Helpers/leo`, always by
/// explicit path (D6): the app owns this command, whatever `leo` is on PATH.
struct LeoHandover: Sendable {
    static let codeNoLaunchdJob = "no_launchd_job"
    /// leo drains for up to 10 minutes by default; never cut it shorter.
    static let timeout: TimeInterval = 11 * 60

    let runner: any LeoProcessRunning
    let bundledLeo: String

    func toApp(label: String) async -> LeoHandoverRun {
        await run(["service", "handover", "--to-app", "--label", label, "--json"])
    }

    func toCLI() async -> LeoHandoverRun {
        await run(["service", "handover", "--to-cli", "--json"])
    }

    private func run(_ arguments: [String]) async -> LeoHandoverRun {
        let result: LeoProcessResult
        do {
            result = try await runner.run(executable: bundledLeo, arguments: arguments, timeout: Self.timeout)
        } catch {
            return .malformed("\(error)")
        }
        guard let decoded = try? JSONDecoder().decode(LeoHandoverResult.self, from: result.stdout) else {
            let stderr = (String(bytes: result.stderr, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .malformed(stderr.isEmpty ? "leo exited \(result.status) without a JSON answer" : stderr)
        }
        // The contract: exit 0 iff ok.
        switch (decoded.ok, result.status == 0) {
        case (true, true): return .succeeded(decoded)
        case (false, false): return .failed(decoded)
        default: return .malformed("leo exited \(result.status) but answered ok:\(decoded.ok)")
        }
    }
}
