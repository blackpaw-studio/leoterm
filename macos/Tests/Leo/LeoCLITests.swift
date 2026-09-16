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

    @Test func resolvesExecutableFromInjectedLocations() throws {
        let executable = Set(["/expanded/override", "/expanded/.local/bin/leo", "/bin/leo"])
        let resolve = { (override: String?, candidates: [String], path: String) throws -> String in
            _ = try LeoCLI.resolveExecutable(
                executableOverride: override,
                candidatePaths: candidates,
                path: path,
                expandTilde: { $0.replacingOccurrences(of: "~", with: "/expanded") },
                isExecutable: { executable.contains($0) }
            )
        }

        #expect(try resolve("~/override", [], "") == "/expanded/override")
        #expect(try resolve(nil, ["~/.local/bin/leo"], "/bin:/usr/bin") == "/expanded/.local/bin/leo")
        #expect(try resolve(nil, ["/missing"], "/missing:/bin:/usr/bin") == "/bin/leo")
    }

    @Test func reportsEveryTriedExecutablePath() {
        do {
            try LeoCLI.resolveExecutable(
                candidatePaths: ["~/.local/bin/leo"],
                path: "/one:/two",
                expandTilde: { $0.replacingOccurrences(of: "~", with: "/home/test") },
                isExecutable: { _ in false }
            )
            Issue.record("Expected executable resolution to fail")
        } catch let error as LeoDaemonError {
            guard case let .transport(message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message == "leo executable not found; tried: /home/test/.local/bin/leo, /one/leo, /two/leo")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
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
