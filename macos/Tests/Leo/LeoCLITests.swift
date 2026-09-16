import Foundation
import Testing

@testable import Ghostty

struct LeoCLITests {
    @Test func usesArgvForTemplateAndHostLists() async throws {
        let runner = CLIFakeRunner()
        let cli = LeoCLI(executableOverride: "/usr/bin/leo", runner: runner)
        _ = try await cli.templateList()
        _ = try await cli.hostList()
        #expect(await runner.arguments == [["template", "list", "--json"], ["host", "list", "--json"]])
    }
}

private actor CLIFakeRunner: LeoProcessRunning {
    var arguments: [[String]] = []
    func run(executable _: String, arguments: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        self.arguments.append(arguments)
        let output = arguments.first == "template" ? #"[{"name":"swift"}]"# : #"[{"name":"localhost","local":true}]"#
        return LeoProcessResult(stdout: Data(output.utf8), stderr: Data(), status: 0)
    }
}
