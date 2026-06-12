import Testing
import Foundation
@testable import Ghostty

struct LeoHostTests {
    @Test func decodesHostListJSON() throws {
        let json = Data("""
        [{"name":"localhost","default":false,"local":true},
         {"name":"cerberus","ssh":"leo@10.0.2.9","default":false,"local":false},
         {"name":"dionysus","ssh":"leo@10.0.2.10","default":true,"local":false}]
        """.utf8)
        let hosts = try JSONDecoder().decode([LeoHost].self, from: json)
        #expect(hosts.count == 3)
        #expect(hosts[0].name == "localhost")
        #expect(hosts[0].isLocal == true)
        #expect(hosts[0].ssh == nil)
        #expect(hosts[0].isDefault == false)
        #expect(hosts[2].name == "dionysus")
        #expect(hosts[2].isDefault == true)
        #expect(hosts[2].ssh == "leo@10.0.2.10")
        #expect(hosts[2].isLocal == false)
    }

    @Test func localhostNameMatchesDaemonConvention() {
        #expect(LeoHost.localhostName == "localhost")
    }

    @Test func isRemoteIsTrueOnlyForNonLocalHosts() {
        let local = LeoHost(name: "localhost", ssh: nil, isDefault: false, isLocal: true)
        let remote = LeoHost(name: "dionysus", ssh: "leo@10.0.2.10", isDefault: true, isLocal: false)
        #expect(local.isRemote == false)
        #expect(remote.isRemote == true)
    }
}
