import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Every enabled machine has its own tunnel, so files on any of them open
/// at once: local for This Mac, SFTP over that machine's ControlMaster for a
/// remote.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor struct LeoMachineRegistryFileAccessTests {
    private typealias Support = LeoMachineRegistryTestSupport

    @Test func thisMacUsesTheLocalFilesystem() throws {
        let registry = LeoMachineRegistry.isolatedForTesting()

        #expect(try registry.makeFileAccess(for: .local) is LeoFileAccessor<LeoLocalFileBackend>)
    }

    @Test func everyRemoteMachineMultiplexesSFTPOverItsOwnControlPath() async throws {
        let defaults = LeoInMemoryDefaults()
        let machines = [Support.host("a"), Support.host("b")]
        try Support.save(machines, to: defaults)
        let tunnels = LeoFakeTunnels()
        machines.forEach { tunnels.script($0.sshTarget, .hangs) }
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels)
        registry.start(flavor: .socketEvents)
        try await until { tunnels.all.count == 2 }

        for configuration in machines {
            let access = try #require(try registry.makeFileAccess(for: .remote(configuration.name)) as? LeoFileAccessor<LeoSFTPFileBackend>)
            let launcher = try #require(access.backend.session.launcher as? LeoSFTPProcessLauncher)
            let controlPath = registry.environment.controlPath(for: configuration)
            #expect(launcher.executable == LeoTunnelTestSupport.fixtureURL())
            #expect(launcher.arguments == (try LeoSSHCommand(configuration: configuration).sftpArguments(controlPath: controlPath)))
            #expect(launcher.fallbackArguments == (try LeoSSHCommand(configuration: configuration).sftpBootstrapArguments(controlPath: controlPath)))
        }
        registry.shutdown()
    }

    @Test func anUnknownOrDisabledMachineHasNoFileAccess() throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("off", enabled: false)], to: defaults)
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults)

        #expect(throws: LeoFileAccessError.disconnected) { try registry.makeFileAccess(for: .remote("off")) }
        #expect(throws: LeoFileAccessError.disconnected) { try registry.makeFileAccess(for: .remote("gone")) }
    }

    /// The OS can purge the cache directory under a live master: with the
    /// tunnel connected and its control socket gone, say to reconnect.
    @Test func aConnectedMachineWhoseControlSocketVanishedSaysToReconnect() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a")], to: defaults)
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults)
        registry.start(flavor: .socketEvents)
        try await until { @MainActor in registry.status(for: .remote("a")) == .connected }

        #expect(throws: LeoFileAccessError.unavailable(reason: LeoMachineRegistry.missingControlSocket)) {
            try registry.makeFileAccess(for: .remote("a"))
        }
        registry.shutdown()
    }
}
