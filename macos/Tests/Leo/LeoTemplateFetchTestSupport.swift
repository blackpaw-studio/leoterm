import Foundation

@testable import Ghostty

/// B-061: the template-fetch runner every `LeoRuntime` test injects, so
/// selecting a remote host never launches a real
/// `ssh … leo template list --json` against one of Evan's hosts. Records
/// each call and answers an empty template list.
actor LeoRecordingTemplateRunner: LeoProcessRunning {
    struct Call: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    private(set) var calls: [Call] = []

    func run(executable: String, arguments: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        calls.append(Call(executable: executable, arguments: arguments))
        return LeoProcessResult(stdout: Data("[]".utf8), stderr: Data(), status: 0)
    }
}
