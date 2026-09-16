import Foundation

@testable import Ghostty

/// Shared helpers for `LeoTunnel`/`LeoTunnelOrphanStore` tests. Fixture lookup
/// mirrors `LeoModelsTests`/`LeoObserveTests`: fixtures under `Tests/Leo/Fixtures`
/// are read directly from the source tree via `#filePath`, not bundled as test
/// resources, since tests run in-host with the source available on disk.
enum LeoTunnelTestSupport {
    static func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake_ssh.py")
    }

    static func socketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lt-\(UUID().uuidString.prefix(8)).sock").path
    }

    static func arguments(socketPath: String) throws -> [String] {
        let fixture = fixtureURL()
        guard FileManager.default.isExecutableFile(atPath: fixture.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return [fixture.path, "-n", "-N", "-L", "\(socketPath):/remote/leo.sock", "host"]
    }

    static func healthProbe(_ path: String) async throws -> Bool {
        let response = try await LeoUnixSocketTransport().send(
            LeoHTTPRequest(method: "GET", path: "/health"), socketPath: path, timeout: 0.2
        )
        return response.status == 200
    }

    static func setEnvironment(_ name: String, _ value: String?) {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }
}
