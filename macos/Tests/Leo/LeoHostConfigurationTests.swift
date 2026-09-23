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
        let second = LeoHostConfiguration(id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!, name: "A_B", sshTarget: "build")
        #expect(first.localSocketFileName == "a_b-000000000000.sock")
        #expect(first.localSocketFileName != second.localSocketFileName)
        #expect(LeoHostConfiguration(name: "..", sshTarget: "build").localSocketFileName != "..")
        #expect(LeoHostConfiguration(name: String(repeating: "a", count: 25), sshTarget: "build").localSocketFileName.hasPrefix(String(repeating: "a", count: 24)))
    }

    /// The ControlMaster socket name: independent of the (renamable) host
    /// name and short, because ssh appends a 17-byte suffix to it while
    /// binding and the whole path must fit the 104-byte AF_UNIX limit.
    @Test func controlSocketFileNameIsShortAndKeyedByID() {
        let first = LeoHostConfiguration(id: UUID(uuidString: "0A000000-0000-0000-0000-000000000001")!, name: "Some long host name", sshTarget: "build")
        let renamed = LeoHostConfiguration(id: first.id, name: "x", sshTarget: "build")
        let second = LeoHostConfiguration(id: UUID(uuidString: "1B000000-0000-0000-0000-000000000002")!, name: "x", sshTarget: "build")
        #expect(first.controlSocketFileName(instance: "1234abcd").hasPrefix("cm-1234abcd-0a0000000000-"))
        #expect(first.controlSocketFileName(instance: "1234abcd") == renamed.controlSocketFileName(instance: "1234abcd"))
        #expect(first.controlSocketFileName(instance: "1234abcd") != second.controlSocketFileName(instance: "1234abcd"))
    }

    /// The debug and production bundles share `~/.leo/state/leoterm`; each
    /// must own its own master socket for the same host.
    @Test func controlSocketFileNameIsScopedToTheAppInstance() {
        let host = LeoHostConfiguration(name: "build", sshTarget: "build")
        let production = LeoHostConfiguration.controlSocketInstance(bundleIdentifier: "studio.blackpaw.leo")
        let debug = LeoHostConfiguration.controlSocketInstance(bundleIdentifier: "studio.blackpaw.leo.debug")

        #expect(production.count == 8)
        #expect(production.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(production == LeoHostConfiguration.controlSocketInstance(bundleIdentifier: "studio.blackpaw.leo"), "stable across launches")
        #expect(host.controlSocketFileName(instance: production) != host.controlSocketFileName(instance: debug))
    }

    /// A master left running by a crashed app must never serve a host
    /// whose connection settings changed since: the name carries a hash of
    /// every input that picks the server.
    @Test func controlSocketFileNameIsStableForTheSameConnection() {
        let id = UUID(uuidString: "0A000000-0000-0000-0000-000000000001")!
        let host = LeoHostConfiguration(id: id, name: "build", sshTarget: "evan@build:2222", identityFile: "~/.ssh/id_build")
        let same = LeoHostConfiguration(id: id, name: "renamed", sshTarget: "evan@build:2222", identityFile: "~/.ssh/id_build")
        #expect(host.controlSocketFileName(instance: "1234abcd") == same.controlSocketFileName(instance: "1234abcd"))
    }

    @Test(arguments: [
        ("evan@other:2222", "~/.ssh/id_build"),
        ("root@build:2222", "~/.ssh/id_build"),
        ("build:2222", "~/.ssh/id_build"),
        ("evan@build:2200", "~/.ssh/id_build"),
        ("evan@build", "~/.ssh/id_build"),
        ("evan@build:2222", "~/.ssh/id_other"),
        ("evan@build:2222", nil)
    ] as [(String, String?)])
    func controlSocketFileNameChangesWithTheConnection(_ target: String, _ identityFile: String?) {
        let id = UUID(uuidString: "0A000000-0000-0000-0000-000000000001")!
        let host = LeoHostConfiguration(id: id, name: "build", sshTarget: "evan@build:2222", identityFile: "~/.ssh/id_build")
        let changed = LeoHostConfiguration(id: id, name: "build", sshTarget: target, identityFile: identityFile)
        #expect(host.controlSocketFileName(instance: "1234abcd") != changed.controlSocketFileName(instance: "1234abcd"))
    }

    /// The connection hash must not eat the path budget: the name stays
    /// short and ssh-safe, so a control path under a typical home stays
    /// within `LeoSSHCommand.isValidControlPath`'s limit.
    @Test func controlSocketFileNameStaysWithinThePathLimit() {
        let host = LeoHostConfiguration(name: "build", sshTarget: "someone@a-very-long-host-name.example.com:65535", identityFile: "/x/y")
        let name = host.controlSocketFileName(instance: LeoHostConfiguration.controlSocketInstance(bundleIdentifier: "studio.blackpaw.leo"))
        let suffix = name.split(separator: "-").last.map(String.init) ?? ""

        #expect(name.utf8.count == 33)
        #expect(suffix.count == 8 && suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(LeoSSHCommand.isValidControlPath("/Users/fifteencharsname/.leo/state/leoterm/" + name))
    }

    @Test(arguments: ["[::1]", "::1", "host:1:2", "[host]:22"])
    func rejectsIPv6Targets(_ target: String) {
        #expect(LeoHostConfiguration(name: "build", sshTarget: target).validate().contains(.ipv6NotSupported))
    }
}
