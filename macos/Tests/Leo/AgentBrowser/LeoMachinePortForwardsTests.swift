import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Each agent browser's URL mapping: This Mac maps nothing; a remote
/// machine's browsers forward through that machine's current connection,
/// whose forwards all close when it drops.
@MainActor
struct LeoMachinePortForwardsTests {
    private static let remote = LeoHostID.remote("dionysus")
    private static let alice = LeoAgentBrowserKey(host: remote, agent: "alice")
    private static let bob = LeoAgentBrowserKey(host: remote, agent: "bob")

    /// One runner per connection, in the order the connections came up.
    private final class Connections {
        var runners: [FakeForwardRunner] = []
        var busy: Set<Int> = []
        var made: [LeoHostID] = []
    }

    private func machines(_ connections: Connections) -> LeoMachinePortForwards {
        LeoMachinePortForwards { host in
            connections.made.append(host)
            let runner = FakeForwardRunner(busy: connections.busy)
            connections.runners.append(runner)
            return LeoPortForwards(
                planner: LeoPortForwardPlanner(isRemote: true, prober: FakePortProber()),
                controlPath: "/tmp/cm", makeMux: { _ in runner }, makeProcess: { runner }
            )
        }
    }

    private func url(_ string: String) throws -> URL { try #require(URL(string: string)) }

    @Test func theLocalMachineMapsNothing() async throws {
        let connections = Connections()
        let machines = machines(connections)
        machines.connected(.local)

        let mapping = machines.mapping(for: LeoAgentBrowserKey(host: .local, agent: "alice"))

        #expect(mapping is LeoIdentityURLMapping)
        #expect(try await mapping.toLocal(url("http://localhost:5173/")) == url("http://localhost:5173/"))
        #expect(connections.made.isEmpty)
    }

    @Test func aRemoteBrowserForwardsThroughItsMachinesConnection() async throws {
        let connections = Connections()
        connections.busy = [5173]
        let machines = machines(connections)
        machines.connected(Self.remote)
        let mapping = machines.mapping(for: Self.alice)

        let local = try await mapping.toLocal(url("http://localhost:5173/app?x=1"))

        #expect(local == (try url("http://localhost:49200/app?x=1")))
        #expect(mapping.toRemote(local) == (try url("http://localhost:5173/app?x=1")))
        #expect(connections.runners.first?.opens.map(\.remote) == [5173, 5173])
        #expect(try await mapping.toLocal(url("https://example.com/")) == url("https://example.com/"))
    }

    @Test func aDropClosesEveryForwardAndTheNextConnectionCarriesOn() async throws {
        let connections = Connections()
        let machines = machines(connections)
        machines.connected(Self.remote)
        let mapping = machines.mapping(for: Self.alice)
        _ = try await mapping.toLocal(url("http://localhost:5173/"))

        await machines.disconnected(Self.remote)

        #expect(connections.runners.first?.closes.map(\.remote) == [5173])
        await #expect(throws: LeoBrowserError.self) { try await mapping.toLocal(self.url("http://localhost:5173/")) }
        #expect(try await mapping.toLocal(url("https://example.com/")) == url("https://example.com/"))

        machines.connected(Self.remote)
        _ = try await mapping.toLocal(url("http://localhost:5173/"))

        #expect(connections.runners.count == 2)
        #expect(connections.runners.last?.opens.map(\.remote) == [5173])
    }

    @Test func aForwardStaysUntilTheLastBrowserHoldingItCloses() async throws {
        let connections = Connections()
        let machines = machines(connections)
        machines.connected(Self.remote)
        _ = try await machines.mapping(for: Self.alice).toLocal(url("http://localhost:5173/"))
        _ = try await machines.mapping(for: Self.bob).toLocal(url("http://localhost:5173/"))

        await machines.release(Self.alice)
        #expect(connections.runners.first?.closes.isEmpty == true)

        await machines.release(Self.bob)
        #expect(connections.runners.first?.closes.map(\.remote) == [5173])
    }

    @Test func aForwardThatCannotOpenFailsTheNavigation() async throws {
        let connections = Connections()
        connections.busy = [5173, 49_200, 49_201, 49_202]
        let machines = machines(connections)
        machines.connected(Self.remote)

        do {
            _ = try await machines.mapping(for: Self.alice).toLocal(url("http://localhost:5173/"))
            Issue.record("expected navigation_failed")
        } catch let error as LeoBrowserError {
            #expect(error.code == .navigationFailed)
            #expect(error.message.contains("5173"))
        }
    }
}
