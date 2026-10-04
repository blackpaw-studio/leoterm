import Foundation

@testable import Ghostty

/// B-061/B-112: the one template-fetch fake every test injects, as
/// `LeoRuntime`'s `templateFetchRunner`, as `LeoAgentActions`'
/// `processRunner`, and behind `LeoCLI.recordingForTests`, so neither a
/// local `leo template list --json` nor a remote
/// `ssh … leo template list --json` ever launches a real process. Records
/// each call and answers with the configured template names (none by
/// default).
actor LeoRecordingTemplateRunner: LeoProcessRunning {
    struct Call: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    private(set) var calls: [Call] = []
    private let stdout: Data

    init(templates: [String] = []) {
        stdout = Self.templateListJSON(templates)
    }

    func run(executable: String, arguments: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        calls.append(Call(executable: executable, arguments: arguments))
        return LeoProcessResult(stdout: stdout, stderr: Data(), status: 0)
    }

    /// The `leo template list --json` payload naming `templates`.
    static func templateListJSON(_ templates: [String]) -> Data {
        (try? JSONEncoder().encode(templates.map { LeoTemplate(name: $0) })) ?? Data("[]".utf8)
    }
}

extension LeoCLI {
    /// A `LeoCLI` whose commands run through `runner` (a fresh
    /// `LeoRecordingTemplateRunner` answering `templates` unless one is
    /// passed), resolving to the fixed executable `/leo` without touching
    /// the filesystem.
    static func recordingForTests(
        templates: [String] = [],
        runner: (any LeoProcessRunning)? = nil
    ) -> LeoCLI {
        LeoCLI(
            executableOverride: "/leo",
            runner: runner ?? LeoRecordingTemplateRunner(templates: templates),
            isExecutable: { _ in true }
        )
    }
}
