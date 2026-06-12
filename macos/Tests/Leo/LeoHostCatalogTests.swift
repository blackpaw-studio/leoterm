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
