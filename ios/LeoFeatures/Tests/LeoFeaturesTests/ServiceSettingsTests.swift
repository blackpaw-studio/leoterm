import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct ServiceSettingsTests {
    @MainActor
    struct Harness {
        let store: TestStore<ServiceSettings.State, ServiceSettings.Action>
        let fake: LeoFakeConfigClient
        let clock: TestClock<Duration>
        let copied: LockIsolated<[String]>

        var state: ServiceSettings.State { store.state }

        func logReads() async -> [LeoFakeConfigCall] {
            await fake.calls.filter { if case .serviceLog = $0 { true } else { false } }
        }
    }

    static func harness(log: String = "started\n") async throws -> Harness {
        let fake = try ConfigGolden.client()
        await fake.setService(LeoFakeServiceState(pid: 10, processes: [LeoServiceProcess(name: "zeus", status: "running")], log: log))
        let clock = TestClock()
        let copied = LockIsolated<[String]>([])
        let connection = DaemonConnection(daemon: .dionysus, secrets: DaemonSecrets(token: "t"))
        let store = TestStore(initialState: ServiceSettings.State(daemon: .dionysus, connection: connection)) {
            ServiceSettings()
        } withDependencies: {
            $0.configClients.client = { _ in fake }
            $0.continuousClock = clock
            $0.pasteboard.copy = { text in copied.withValue { $0.append(text) } }
        }
        store.exhaustivity = .off
        return Harness(store: store, fake: fake, clock: clock, copied: copied)
    }

    @Test func appearingReadsTheStatusAndTheLog() async throws {
        let harness = try await Self.harness()

        await harness.store.send(.appeared)
        await harness.store.receive(\.statusLoaded)
        await harness.store.receive(\.logPolled)

        #expect(harness.state.status == .loaded(try await harness.fake.serviceStatus()))
        #expect(harness.state.logText == "started\n")
        #expect(await harness.logReads() == [.serviceLog(lines: 200)])
    }

    @Test func pollsEvery2sWhileVisible() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.appeared)
        await harness.store.receive(\.logPolled)

        await harness.clock.advance(by: .seconds(1))
        #expect(await harness.logReads().count == 1)
        await harness.clock.advance(by: .seconds(1))
        await harness.store.receive(\.logPolled)
        await harness.clock.advance(by: .seconds(2))
        await harness.store.receive(\.logPolled)

        #expect(await harness.logReads().count == 3)
    }

    @Test func stopsWhenHidden() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.appeared)
        await harness.store.receive(\.logPolled)

        await harness.store.send(.disappeared)
        await harness.clock.advance(by: .seconds(10))

        #expect(await harness.logReads().count == 1)
    }

    @Test func stopsInBackgroundAndResumesInForeground() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.appeared)
        await harness.store.receive(\.logPolled)

        await harness.store.send(.machine(.scenePhaseChanged(isActive: false)))
        await harness.clock.advance(by: .seconds(10))
        #expect(await harness.logReads().count == 1)

        await harness.store.send(.machine(.scenePhaseChanged(isActive: true)))
        await harness.store.receive(\.logPolled)
        #expect(await harness.logReads().count == 2)
    }

    @Test func pauseStops() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.appeared)
        await harness.store.receive(\.logPolled)

        await harness.store.send(.pauseTapped)
        await harness.clock.advance(by: .seconds(10))
        #expect(await harness.logReads().count == 1)

        await harness.store.send(.resumeTapped)
        await harness.store.receive(\.logPolled)
        #expect(await harness.logReads().count == 2)
    }

    @Test func appearingTwiceKeepsOneLoop() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.appeared)
        await harness.store.receive(\.logPolled)
        await harness.store.send(.appeared)

        await harness.clock.advance(by: .seconds(2))
        await harness.store.receive(\.logPolled)

        #expect(await harness.logReads().count == 2)
    }

    @Test func copyWritesShownText() async throws {
        let harness = try await Self.harness(log: "one\ntwo\n")
        await harness.store.send(.appeared)
        await harness.store.receive(\.logPolled)

        await harness.store.send(.copyTapped)

        #expect(harness.copied.value == ["one\ntwo\n"])
    }

    @Test func theShownLogIsBounded() async throws {
        let long = String(repeating: "0123456789abcdef\n", count: 40_000)
        let harness = try await Self.harness(log: long)

        await harness.store.send(.appeared)
        await harness.store.receive(\.logPolled)

        #expect(harness.state.logText.utf8.count <= LeoTaskLog.displayLimit)
        #expect(harness.state.logText.hasSuffix("0123456789abcdef\n"))
    }

    @Test func aFailedPollKeepsTheTextAndSaysWhy() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.appeared)
        await harness.store.receive(\.logPolled)
        await harness.fake.failNextRead(with: LeoDaemonError.daemon(code: "unavailable", message: "down", matches: []))

        await harness.clock.advance(by: .seconds(2))
        await harness.store.receive(\.logPolled)

        #expect(harness.state.logText == "started\n")
        #expect(harness.state.logError != nil)
    }
}
