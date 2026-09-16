import Foundation
import Testing

@testable import Ghostty

struct LeoHostConfigurationTests {
    @Test func jsonRoundTripPreservesConfiguration() throws {
        let configuration = LeoHostConfiguration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Build Mac",
            sshTarget: "evan@build.example:2222",
            identityFile: "/Users/evan/.ssh/build key",
            remoteLeoPath: "/opt/leo bin/leo",
            remoteSocketPath: "/var/run/leo.sock"
        )

        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(LeoHostConfiguration.self, from: data) == configuration)
        #expect(configuration.user == "evan")
        #expect(configuration.host == "build.example")
        #expect(configuration.port == 2222)
    }

    @Test func defaultsAndPlainHostAreApplied() {
        let configuration = LeoHostConfiguration(name: "Build", sshTarget: "build.example")
        #expect(configuration.remoteLeoPath == "~/.local/bin/leo")
        #expect(configuration.remoteSocketPath == "~/.leo/state/leo.sock")
        #expect(configuration.user == nil)
        #expect(configuration.host == "build.example")
        #expect(configuration.port == nil)
    }

    @Test(arguments: [
        (LeoHostConfiguration(name: " ", sshTarget: "build"), LeoHostValidationError.emptyName),
        (LeoHostConfiguration(name: "localhost", sshTarget: "build"), LeoHostValidationError.reservedName),
        (LeoHostConfiguration(name: "build", sshTarget: " "), LeoHostValidationError.emptySSHTarget),
        (LeoHostConfiguration(name: "build", sshTarget: "host:no"), LeoHostValidationError.malformedPort),
        (LeoHostConfiguration(name: "build", sshTarget: "host:0"), LeoHostValidationError.malformedPort),
        (LeoHostConfiguration(name: "build", sshTarget: "host:-1"), LeoHostValidationError.malformedPort),
        (LeoHostConfiguration(name: "build", sshTarget: "host:65536"), LeoHostValidationError.malformedPort),
        (LeoHostConfiguration(name: "bad/name", sshTarget: "build"), LeoHostValidationError.invalidName),
        (LeoHostConfiguration(name: "bad\0name", sshTarget: "build"), LeoHostValidationError.invalidName),
        (LeoHostConfiguration(name: "build", sshTarget: "-unsafe"), LeoHostValidationError.unsafeSSHTarget),
        (LeoHostConfiguration(name: "build", sshTarget: " -unsafe"), LeoHostValidationError.unsafeSSHTarget),
        (LeoHostConfiguration(name: "build", sshTarget: "@-V"), LeoHostValidationError.unsafeSSHTarget),
        (LeoHostConfiguration(name: "build", sshTarget: "-oProxyCommand=x@host"), LeoHostValidationError.unsafeSSHTarget),
        (LeoHostConfiguration(name: "build", sshTarget: "user@-V"), LeoHostValidationError.unsafeSSHTarget),
        (LeoHostConfiguration(name: "build", sshTarget: "user name@host"), LeoHostValidationError.unsafeSSHTarget),
        (LeoHostConfiguration(name: "build", sshTarget: "user@host\nname"), LeoHostValidationError.unsafeSSHTarget),
        (LeoHostConfiguration(name: "build", sshTarget: "host", identityFile: "-unsafe"), LeoHostValidationError.unsafeIdentityFile)
    ])
    func validatesInvalidValues(_ configuration: LeoHostConfiguration, _ error: LeoHostValidationError) {
        #expect(configuration.validate().contains(error))
    }

    @Test func localSocketNameIsSafeUniqueAndNeverDotDot() {
        let first = LeoHostConfiguration(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "A B", sshTarget: "build")
        let second = LeoHostConfiguration(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "A_B", sshTarget: "build")
        #expect(first.localSocketFileName == "a_b-00000000000000000000000000000001.sock")
        #expect(first.localSocketFileName != second.localSocketFileName)
        #expect(LeoHostConfiguration(name: "..", sshTarget: "build").localSocketFileName != "..")
        #expect(LeoHostConfiguration(name: String(repeating: "a", count: 25), sshTarget: "build").localSocketFileName.hasPrefix(String(repeating: "a", count: 24)))
    }

    @Test(arguments: ["[::1]", "::1", "host:1:2", "[host]:22"])
    func rejectsIPv6Targets(_ target: String) {
        #expect(LeoHostConfiguration(name: "build", sshTarget: target).validate().contains(.ipv6NotSupported))
    }
}
