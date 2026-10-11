import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct TerminalTests {
    let ref = AgentRef(daemonID: PairedDaemon.dionysus.id, name: "zeus")
    let streams = Streams<LeoTerminalEvent>(count: 3)
    let requested = LockIsolated<[TerminalSize]>([])
    let clock = TestClock()
    let bus = TerminalOutputBus()

    func makeStore(isAgentRunning: Bool = true) -> TestStoreOf<Terminal> {
        let (streams, requested, clock, bus) = (streams, requested, clock, bus)
        return TestStore(initialState: Terminal.State(daemon: .dionysus, agentName: "zeus", isAgentRunning: isAgentRunning)) {
            Terminal()
        } withDependencies: {
            $0.continuousClock = clock
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.terminalClient.attach = { _, agent, size in
                requested.withValue { $0.append(size) }
                return streams.next()
            }
            $0.terminalOutput = bus
        }
    }

    @Test func connectsGoesLiveAndForwardsOutputToTheView() async {
        let output = bus.output(for: ref)
        let store = makeStore()

        await store.send(.appeared) {
            $0.isVisible = true
            $0.phase = .connecting
        }
        streams[0].yield(.opened)
        await store.receive(\.opened) { $0.phase = .live }
        streams[0].yield(.output(Data("hello".utf8)))

        var iterator = output.makeAsyncIterator()
        #expect(await iterator.next() == .reset)
        #expect(await iterator.next() == .bytes(Data("hello".utf8)))
        #expect(requested.value == [TerminalSize.standard])

        await store.send(.disappeared) {
            $0.isVisible = false
            $0.phase = .idle
        }
        #expect(streams.terminated.value == 1)
    }

    @Test func aDroppedConnectionRetriesWithBackoff() async {
        let store = makeStore()
        await store.send(.appeared) {
            $0.isVisible = true
            $0.phase = .connecting
        }
        streams[0].yield(.opened)
        await store.receive(\.opened) { $0.phase = .live }

        streams[0].finish(throwing: LeoDaemonError.transport("lost"))
        await store.receive(\.ended) {
            $0.failures = 1
            $0.phase = .disconnected(attempt: 1, reason: LeoDaemonError.transport("lost").localizedDescription)
        }
        await clock.advance(by: .milliseconds(999))
        #expect(streams.opened.value == 1)
        await clock.advance(by: .milliseconds(1))
        await store.receive(\.connect) { $0.phase = .connecting }

        streams[1].finish(throwing: LeoTerminalAttachError.idleTimeout)
        await store.receive(\.ended) {
            $0.failures = 2
            $0.phase = .disconnected(attempt: 2, reason: LeoTerminalAttachError.idleTimeout.localizedDescription)
        }
        await clock.advance(by: .seconds(2))
        await store.receive(\.connect) { $0.phase = .connecting }
        streams[2].yield(.opened)
        await store.receive(\.opened) {
            $0.phase = .live
            $0.failures = 0
        }
        await store.send(.disappeared) {
            $0.isVisible = false
            $0.phase = .idle
        }
    }

    @Test(arguments: [
        LeoTerminalAttachError.closed(code: 1008, reason: "device revoked"),
        LeoTerminalAttachError.rejected(status: 401),
    ])
    func aRevokedDeviceStopsWithoutRetrying(end: LeoTerminalAttachError) async {
        let store = makeStore()
        await store.send(.appeared) {
            $0.isVisible = true
            $0.phase = .connecting
        }
        streams[0].finish(throwing: end)
        await store.receive(\.ended) { $0.phase = .revoked }
        await clock.run()
        #expect(streams.opened.value == 1)
    }

    @Test func backgroundingClosesTheSocketAndForegroundingReconnects() async {
        let store = makeStore()
        await store.send(.appeared) {
            $0.isVisible = true
            $0.phase = .connecting
        }
        streams[0].yield(.opened)
        await store.receive(\.opened) { $0.phase = .live }

        await store.send(.scenePhaseChanged(isActive: false)) {
            $0.isSceneActive = false
            $0.phase = .paused
        }
        #expect(streams.terminated.value == 1)
        await clock.run()
        #expect(streams.opened.value == 1)

        await store.send(.scenePhaseChanged(isActive: true)) {
            $0.isSceneActive = true
            $0.phase = .connecting
        }
        #expect(streams.opened.value == 2)
        await store.send(.disappeared) {
            $0.isVisible = false
            $0.phase = .idle
        }
    }

    @Test func aStoppedAgentIsNotRunningUntilItStarts() async {
        let store = makeStore(isAgentRunning: false)
        await store.send(.appeared) {
            $0.isVisible = true
            $0.phase = .notRunning
        }
        #expect(streams.opened.value == 0)

        await store.send(.agentRunningChanged(true)) {
            $0.isAgentRunning = true
            $0.phase = .connecting
        }
        streams[0].yield(.opened)
        await store.receive(\.opened) { $0.phase = .live }

        await store.send(.agentRunningChanged(false)) {
            $0.isAgentRunning = false
            $0.phase = .notRunning
        }
        #expect(streams.terminated.value == 1)
        await store.send(.disappeared) {
            $0.isVisible = false
            $0.phase = .idle
        }
    }

    @Test func anUnknownAgentIsNotRunningAndIsNotRetried() async {
        let store = makeStore()
        await store.send(.appeared) {
            $0.isVisible = true
            $0.phase = .connecting
        }
        streams[0].finish(throwing: LeoTerminalAttachError.rejected(status: 404))
        await store.receive(\.ended) { $0.phase = .notRunning }
        await clock.run()
        #expect(streams.opened.value == 1)
    }

    @Test func aSessionThatEndsWhileTheAgentRunsIsRetried() async {
        let store = makeStore()
        await store.send(.appeared) {
            $0.isVisible = true
            $0.phase = .connecting
        }
        streams[0].finish(throwing: LeoTerminalAttachError.closed(code: 1000, reason: "session ended"))
        await store.receive(\.ended) {
            $0.failures = 1
            $0.phase = .disconnected(attempt: 1, reason: "The agent's session ended.")
        }
        await clock.advance(by: .seconds(1))
        await store.receive(\.connect) { $0.phase = .connecting }
        await store.send(.disappeared) {
            $0.isVisible = false
            $0.phase = .idle
            $0.failures = 0
        }
    }

    @Test func choosingASizeReconnectsAtThatSize() async {
        let store = makeStore()
        await store.send(.appeared) {
            $0.isVisible = true
            $0.phase = .connecting
        }
        streams[0].yield(.opened)
        await store.receive(\.opened) { $0.phase = .live }

        await store.send(.sizeSelected(.wide)) {
            $0.$size.withLock { $0 = .wide }
            $0.phase = .connecting
        }
        #expect(requested.value == [.standard, .wide])
        #expect(streams.terminated.value == 1)
        await store.send(.disappeared) {
            $0.isVisible = false
            $0.phase = .idle
        }
    }

    @Test func aMissingTokenIsTreatedAsRevoked() async {
        let store = makeStore()
        store.dependencies.secrets.load = { _ in nil }
        await store.send(.appeared) {
            $0.isVisible = true
            $0.phase = .connecting
        }
        await store.receive(\.ended) { $0.phase = .revoked }
        #expect(streams.opened.value == 0)
    }
}
