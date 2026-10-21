import Foundation

/// leo's `--json` rule: exit 0 prints the command's result (`"ok": true`);
/// anything else prints a failure with a stable `error` code.
enum LeoJSONAnswer<Success: Decodable & Equatable & Sendable>: Equatable, Sendable {
    case succeeded(Success)
    case failed(LeoJSONFailure)
    /// Not JSON, or a JSON answer that disagrees with the exit status.
    case malformed(String)

    init(_ result: LeoProcessResult) {
        let decoder = JSONDecoder()
        let ok = (try? decoder.decode(OKField.self, from: result.stdout))?.ok
        if result.status == 0 {
            if ok == true, let success = try? decoder.decode(Success.self, from: result.stdout) {
                self = .succeeded(success)
            } else {
                self = .malformed(Self.describe(result, expected: "an \"ok\": true answer"))
            }
        } else if ok != true, let failure = try? decoder.decode(LeoJSONFailure.self, from: result.stdout), !failure.error.isEmpty {
            self = .failed(failure)
        } else {
            self = .malformed(Self.describe(result, expected: "an error code"))
        }
    }

    /// Never stdout: a handover's carries the CLI plist's environment.
    private static func describe(_ result: LeoProcessResult, expected: String) -> String {
        let stderr = (String(bytes: result.stderr, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = stderr.isEmpty ? "" : ": \(stderr)"
        return "leo exited \(result.status) without \(expected)\(detail)"
    }

    private struct OKField: Decodable {
        let ok: Bool?
    }
}

/// Every `--json` failure: `{error, message?}`. A handover's step failure
/// also carries `step`, `rolled_back`, `managed_stopped` and `warnings`.
struct LeoJSONFailure: Equatable, Sendable {
    let error: String
    let message: String?
    let step: String?
    let rolledBack: Bool?
    let managedStopped: Bool?
    let warnings: [String]

    /// What to show the user.
    var summary: String { message ?? error }
}

extension LeoJSONFailure: Decodable {
    private enum CodingKeys: String, CodingKey {
        case error, message, step, warnings
        case rolledBack = "rolled_back"
        case managedStopped = "managed_stopped"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            error: try container.decode(String.self, forKey: .error),
            message: try container.decodeIfPresent(String.self, forKey: .message),
            step: try container.decodeIfPresent(String.self, forKey: .step),
            rolledBack: try container.decodeIfPresent(Bool.self, forKey: .rolledBack),
            managedStopped: try container.decodeIfPresent(Bool.self, forKey: .managedStopped),
            warnings: try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        )
    }
}
