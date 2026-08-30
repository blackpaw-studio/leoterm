import Testing
import Foundation
@testable import Ghostty

struct LeoHostCatalogTests {
    private static let fixtureJSON = Data("""
    [{"name":"localhost","default":false,"local":true},
     {"name":"cerberus","ssh":"leo@10.0.2.9","default":false,"local":false},
     {"name":"dionysus","ssh":"leo@10.0.2.10","default":true,"local":false}]
    """.utf8)

    @Test func listHostsDecodesInjectedJSON() async throws {
        let catalog = LeoHostCatalog(runner: { _ in Self.fixtureJSON })
        let hosts = try await catalog.listHosts()
        #expect(hosts.count == 3)
        #expect(hosts[0].name == "localhost")
        #expect(hosts[0].isLocal == true)
        #expect(hosts[2].name == "dionysus")
        #expect(hosts[2].isDefault == true)
        #expect(hosts[2].ssh == "leo@10.0.2.10")
    }

    @Test func listHostsInvokesRunnerWithHostListJSONArgs() async throws {
        let recorder = ArgRecorder()
        let catalog = LeoHostCatalog(runner: { args in
            await recorder.record(args)
            return Self.fixtureJSON
        })
        _ = try await catalog.listHosts()
        #expect(await recorder.args == ["host", "list", "--json"])
    }

    @Test func listHostsSurfacesRunnerError() async {
        let catalog = LeoHostCatalog(runner: { _ throws(LeoError) in throw LeoError.daemonUnreachable })
        await #expect(throws: LeoError.daemonUnreachable) {
            _ = try await catalog.listHosts()
        }
    }

    @Test func listHostsWrapsDecodeFailures() async {
        let catalog = LeoHostCatalog(runner: { _ in Data("not json".utf8) })
        await #expect(throws: LeoError.self) {
            _ = try await catalog.listHosts()
        }
    }
}

private actor ArgRecorder {
    private(set) var args: [String] = []
    func record(_ args: [String]) { self.args = args }
}

/// `LeoProcessRunner` is the blocking `Process` shim behind `LeoHostCatalog`
/// and the `LeoSocketClient` CLI fallback, so it lives with the catalog tests.
struct LeoProcessRunnerTests {
    private static let shell = "/bin/sh"

    @Test func returnsStdoutForASuccessfulRun() async throws {
        let data = try await LeoProcessRunner.runAsync(executable: Self.shell, args: ["-c", "printf hello"])
        #expect(String(bytes: data, encoding: .utf8) == "hello")
    }

    /// Regression: an undrained stderr pipe fills its 64KB buffer and blocks the
    /// child forever (real `leo` calls tunnel through ssh, which is chatty).
    @Test func doesNotDeadlockOnLargeStderrOutput() async throws {
        let script = "yes 'ssh warning line' | head -c 400000 >&2; printf done"
        let data = try await LeoProcessRunner.runAsync(executable: Self.shell, args: ["-c", script], timeout: 20)
        #expect(String(bytes: data, encoding: .utf8) == "done")
    }

    /// A wedged child (an ssh prompt, a dead host) must be terminated rather
    /// than hanging the caller.
    @Test func terminatesAndThrowsOnTimeout() async throws {
        await #expect(throws: LeoError.self) {
            _ = try await LeoProcessRunner.runAsync(
                executable: Self.shell, args: ["-c", "sleep 30"], timeout: 0.3)
        }
    }

    @Test func nonZeroExitIncludesStderrTail() async throws {
        await #expect(throws: LeoError.self) {
            _ = try await LeoProcessRunner.runAsync(
                executable: Self.shell, args: ["-c", "echo boom >&2; exit 3"])
        }
        do {
            _ = try await LeoProcessRunner.runAsync(executable: Self.shell, args: ["-c", "echo boom >&2; exit 3"])
        } catch {
            #expect(error.errorDescription?.contains("boom") == true)
            #expect(error.errorDescription?.contains("exited 3") == true)
        }
    }

    @Test func throwsWhenExecutableIsMissing() async throws {
        await #expect(throws: LeoError.daemonUnreachable) {
            _ = try await LeoProcessRunner.runAsync(executable: "/nonexistent/leo", args: ["host", "list"])
        }
    }
}
