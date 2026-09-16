import Foundation
import Testing

@testable import Ghostty

struct LeoProcessRunnerTests {
    @Test func fastProcessesAlwaysCaptureOutput() async throws {
        let runner = LeoProcessRunner()
        for _ in 0..<50 {
            let start = ContinuousClock.now
            let result = try await runner.run(executable: "/bin/echo", arguments: ["hi"], timeout: 1)
            #expect(start.duration(to: .now) < .seconds(1))
            #expect(result.stdout == Data("hi\n".utf8))
        }
    }

    @Test func capturesLargeOutputWithoutDeadlocking() async throws {
        let result = try await LeoProcessRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", "yes | head -c 200000"],
            timeout: 1
        )
        #expect(result.stdout.count == 200_000)
    }

    @Test func timeoutTerminatesProcess() async {
        let start = ContinuousClock.now
        do {
            _ = try await LeoProcessRunner().run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.2)
            Issue.record("Expected process to time out")
        } catch let error as LeoDaemonError {
            #expect(error == .timeout)
            #expect(start.duration(to: .now) < .seconds(1))
        } catch {
            Issue.record("Expected timeout, got \(error)")
        }
    }
}
