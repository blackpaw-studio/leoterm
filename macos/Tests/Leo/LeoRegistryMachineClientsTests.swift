import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// A machine's client is handed out only for that machine's live
/// connection: never before it connects, never once a newer connection has
/// begun, and never for another machine.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor struct LeoRegistryMachineClientsTests {
    private typealias Support = LeoMachineRegistryTestSupport

    @Test func aBoundClientIsHandedOutOnlyWhileItsConnectionIsTheMachinesLiveOne() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("a"), Support.host("b")], to: defaults)
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@b", .ready, .hangs)
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels)
        let clients = LeoRegistryMachineClients(registry: registry)
        registry.start(flavor: .socketEvents)
        try await until { @MainActor in registry.status(for: .remote("b")) == .connected }
        let daemon = RuntimeTestDaemon()

        clients.bind(daemon, host: .remote("b"), generation: registry.generation(for: .remote("b")))
        #expect((clients.daemon(for: .remote("b")) as? RuntimeTestDaemon) === daemon)
        #expect(clients.daemon(for: .remote("a")) == nil, "b's client was handed out for a")

        registry.reconnect(.remote("b"))
        #expect(clients.daemon(for: .remote("b")) == nil, "a stale connection's client was handed out")
        registry.shutdown()
    }

    @Test func aMachineThatIsStillConnectingHasNoClient() async throws {
        let defaults = LeoInMemoryDefaults()
        try Support.save([Support.host("b")], to: defaults)
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@b", .hangs)
        let registry = LeoMachineRegistry.isolatedForTesting(defaults: defaults, tunnels: tunnels)
        let clients = LeoRegistryMachineClients(registry: registry)
        registry.start(flavor: .socketEvents)
        try await until { tunnels.all.count == 1 }

        clients.bind(RuntimeTestDaemon(), host: .remote("b"), generation: registry.generation(for: .remote("b")))

        #expect(clients.daemon(for: .remote("b")) == nil)
        registry.shutdown()
    }
}
