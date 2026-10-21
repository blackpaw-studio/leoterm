import Foundation

/// `leo service handover … --json`'s success, both ways (leo's
/// `docs/configuration/managed-install.md`).
struct LeoHandoverResult: Equatable, Sendable {
    let previousLabel: String?
    /// `--to-app`: the CLI daemon's environment, for the marker's `env` (D5).
    /// May hold secrets: never log it.
    let env: [String: String]?
    let plistBackup: String?
    /// `--to-cli`: leo booted the app's job out, so the app unregisters it.
    let managedStopped: Bool
    let warnings: [String]
}

extension LeoHandoverResult: Decodable {
    private enum CodingKeys: String, CodingKey {
        case env, warnings
        case previousLabel = "previous_label"
        case plistBackup = "plist_backup"
        case managedStopped = "managed_stopped"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            previousLabel: try container.decodeIfPresent(String.self, forKey: .previousLabel),
            env: try container.decodeIfPresent([String: String].self, forKey: .env),
            plistBackup: try container.decodeIfPresent(String.self, forKey: .plistBackup),
            managedStopped: try container.decodeIfPresent(Bool.self, forKey: .managedStopped) ?? false,
            warnings: try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        )
    }
}

typealias LeoHandoverRun = LeoJSONAnswer<LeoHandoverResult>

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
        do {
            return LeoHandoverRun(try await runner.run(executable: bundledLeo, arguments: arguments, timeout: Self.timeout))
        } catch {
            return .malformed("\(error)")
        }
    }
}
