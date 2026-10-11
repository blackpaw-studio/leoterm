import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

/// The fleet's surfaced-file index and seen ledger, and how the agent
/// screen and its Files list follow them.
@MainActor
struct SurfacedFilesTests {
    let ref = AgentRef(daemonID: PairedDaemon.dionysus.id, name: "zeus")
    let a = LeoSurfacedFile.make("a", minute: 0)
    let b = LeoSurfacedFile.make("b", minute: 5)

    @Test func mergesFilesFromStateAndEventsNewestFirst() async {
        let streams = StreamQueue(count: 1)
        let snapshot = LeoObservedState(agents: [.make("zeus", startedAt: "s1", surfacedFiles: [a, b])])
        let store = TestStore(initialState: Fleet.State(daemons: [.dionysus])) {
            Fleet()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.events = { streams.next($0) }
            $0.daemonClient.fetchState = { _ in snapshot }
        }
        store.exhaustivity = .off
        await store.send(.scenePhaseChanged(isActive: true))
        streams[0].yield(.hello(seq: 1, at: nil, version: nil, serverTime: nil))
        await store.receive(\.connected)
        #expect(store.state.surfacedFiles(for: ref).map(\.id) == ["b", "a"])

        let c = LeoSurfacedFile.make("c", minute: 10)
        let delayed = LeoSurfacedFile.make("d", minute: 2)
        let otherIncarnation = LeoSurfacedFile.make("e", minute: 11, startedAt: "s0")
        for (seq, file) in [(2, c), (3, delayed), (4, c), (5, otherIncarnation)] {
            streams[0].yield(.fileSurfaced(seq: seq, file: file))
            await store.receive(\.eventReceived)
        }
        #expect(store.state.surfacedFiles(for: ref).map(\.id) == ["c", "b", "d", "a"])

        // A recovery snapshot keeps what only an event reported.
        await store.send(.snapshotLoaded(ref.daemonID, snapshot))
        #expect(store.state.surfacedFiles(for: ref).map(\.id) == ["c", "b", "d", "a"])
        await store.send(.scenePhaseChanged(isActive: false))
    }

    @Test func aDaemonRestartForgetsTheFilesOfTheOldBoot() async {
        var state = Fleet.State(daemons: [.dionysus])
        state.sessions[0].applySnapshot(LeoObservedState(agents: [.make("zeus", startedAt: "s1", surfacedFiles: [a])]), bootID: "boot-1")
        #expect(state.surfacedFiles(for: ref).map(\.id) == ["a"])
        state.sessions[0].applySnapshot(LeoObservedState(agents: [.make("zeus", startedAt: "s1")]), bootID: "boot-2")
        #expect(state.surfacedFiles(for: ref).isEmpty)
    }

    @Test func openingAFileMarksItSeenAndASnapshotNeverReBadgesIt() async {
        let saved = LockIsolated<[LeoSurfacedFileLedger]>([])
        var initial = Fleet.State(daemons: [.dionysus])
        initial.sessions[0].applySnapshot(LeoObservedState(agents: [.make("zeus", startedAt: "s1", surfacedFiles: [a, b])]))
        let store = TestStore(initialState: initial) {
            Fleet()
        } withDependencies: {
            $0.seenFiles.save = { ledger in saved.withValue { $0.append(ledger) } }
        }
        #expect(store.state.unseenFileIDs(for: ref) == ["a", "b"])

        await store.send(.fileOpened(ref.daemonID, a)) {
            $0.seen = $0.seen.markingSeen(self.a, host: .remote(PairedDaemon.dionysus.id))
        }
        #expect(store.state.unseenFileIDs(for: ref) == ["b"])
        #expect(saved.value.last?.isSeen(a, host: .remote(PairedDaemon.dionysus.id)) == true)

        await store.send(.snapshotLoaded(ref.daemonID, LeoObservedState(agents: [.make("zeus", startedAt: "s1", surfacedFiles: [a, b])])))
        #expect(store.state.unseenFileIDs(for: ref) == ["b"])

        // Opening it again changes nothing and saves nothing.
        await store.send(.fileOpened(ref.daemonID, a))
        #expect(saved.value.count == 1)
    }

    @Test func theSeenLedgerLoadsWithThePairedDaemons() async {
        let ledger = LeoSurfacedFileLedger().markingSeen(a, host: .remote(PairedDaemon.dionysus.id))
        let store = TestStore(initialState: Fleet.State()) {
            Fleet()
        } withDependencies: {
            $0.pairedDaemons.load = { [] }
            $0.seenFiles.load = { ledger }
        }
        await store.send(.task)
        await store.receive(\.daemonsLoaded) { $0.seen = ledger }
    }

    @Test func theAgentScreenAndItsFilesListFollowTheFleet() async {
        let saved = LockIsolated(0)
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.fleet.sessions[0].connection = .connected
        initial.fleet.sessions[0].applySnapshot(LeoObservedState(agents: [.make("zeus", startedAt: "s1", surfacedFiles: [a])]))
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.seenFiles.save = { _ in saved.withValue { $0 += 1 } }
        }
        await store.send(.agentTapped(ref)) {
            $0.detail = AgentDetail.State(daemon: .dionysus, agent: $0.fleet.agent(self.ref)!, connection: .connected)
            $0.detail?.files = [self.a]
            $0.detail?.unseenFileIDs = ["a"]
        }
        await store.send(\.detail.filesButtonTapped) {
            $0.detail?.destination = .files(Files.State(daemon: .dionysus, agentName: "zeus", files: [self.a], unseenIDs: ["a"]))
        }

        await store.send(.fleet(.eventReceived(ref.daemonID, .fileSurfaced(seq: 9, file: b)))) {
            $0.fleet.sessions[0].surfaced = $0.fleet.sessions[0].surfaced.inserting(self.b).index
            $0.detail?.files = [self.b, self.a]
            $0.detail?.unseenFileIDs = ["a", "b"]
            $0.detail?.destination?.modify(\.files) {
                $0.files = [self.b, self.a]
                $0.unseenIDs = ["a", "b"]
            }
        }

        await store.send(\.detail.destination.files.delegate.opened, b) {
            $0.fleet.seen = $0.fleet.seen.markingSeen(self.b, host: .remote(PairedDaemon.dionysus.id))
            $0.detail?.unseenFileIDs = ["a"]
            $0.detail?.destination?.modify(\.files) { $0.unseenIDs = ["a"] }
        }
        #expect(saved.value == 1)
    }

    @Test func theTerminalFollowsTheAgentAndTheScene() async {
        let agent = Agent(.make("zeus", startedAt: "s1"))
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.fleet.isActive = true
        initial.fleet.sessions[0].agents = [agent]
        initial.detail = AgentDetail.State(daemon: .dionysus, agent: agent, connection: .offline)
        initial.detail?.destination = .terminal(Terminal.State(daemon: .dionysus, agentName: "zeus", isAgentRunning: true))
        let store = TestStore(initialState: initial) { AppFeature() }

        await store.send(.fleet(.eventReceived(ref.daemonID, .agentStopped(seq: 2, at: nil, agent: "zeus", wakeOnMessage: nil)))) {
            $0.fleet.sessions[0].agents[0].status = .stopped
            $0.fleet.sessions[0].agents[0].activity = .unknown
            let stopped = $0.fleet.sessions[0].agents[0]
            $0.detail?.agent = stopped
        }
        await store.receive(\.detail.destination.terminal.agentRunningChanged) {
            $0.detail?.destination?.modify(\.terminal) { $0.isAgentRunning = false }
        }

        await store.send(.scenePhaseChanged(isActive: false)) {
            $0.fleet.isActive = false
            $0.fleet.sessions[0].connection = .offline
        }
        await store.receive(\.detail.destination.terminal.scenePhaseChanged) {
            $0.detail?.destination?.modify(\.terminal) { $0.isSceneActive = false }
        }
    }

    // MARK: Replacing or removing the selected agent

    func twoAgentsWithZeusOpen(_ destination: AgentDetail.Destination.State) -> AppFeature.State {
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.fleet.sessions[0].agents = [Agent(.make("zeus", startedAt: "s1")), Agent(.make("hera", startedAt: "s1"))]
        initial.detail = AgentDetail.State(daemon: .dionysus, agent: initial.fleet.sessions[0].agents[0], connection: .offline)
        initial.detail?.destination = destination
        return initial
    }

    var hera: AgentRef { AgentRef(daemonID: PairedDaemon.dionysus.id, name: "hera") }

    @Test func switchingAgentsClosesThePreviousAgentsTerminal() async {
        let streams = Streams<LeoTerminalEvent>(count: 1)
        let initial = twoAgentsWithZeusOpen(.terminal(Terminal.State(daemon: .dionysus, agentName: "zeus", isAgentRunning: true)))
        let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.terminalClient.attach = { _, _, _ in streams.next() }
        }

        await store.send(\.detail.destination.terminal.appeared) {
            $0.detail?.destination?.modify(\.terminal) {
                $0.isVisible = true
                $0.phase = .connecting
            }
        }
        await store.send(.agentTapped(hera)) {
            $0.detail = AgentDetail.State(daemon: .dionysus, agent: $0.fleet.agent(self.hera)!, connection: .offline)
        }
        await store.finish()
        #expect(streams.terminated.value == 1)
    }

    func filesWithPreview(_ preview: FilePreview.State) -> AgentDetail.Destination.State {
        var files = Files.State(daemon: .dionysus, agentName: "zeus", files: [], unseenIDs: [])
        files.preview = preview
        return .files(files)
    }

    var openPreview: FilePreview.State {
        var preview = FilePreview.State(
            daemon: .dionysus, file: a, localURL: URL(fileURLWithPath: "/tmp/leo-previews/1/a.md"), kind: .markdown, text: "x",
            totalBytes: 9, isTruncated: true
        )
        preview.fullFileURL = URL(fileURLWithPath: "/tmp/leo-previews/2/a.md")
        return preview
    }

    @Test func switchingAgentsDeletesTheOpenPreview() async {
        let discarded = LockIsolated<[URL]>([])
        let store = TestStore(initialState: twoAgentsWithZeusOpen(filesWithPreview(openPreview))) { AppFeature() } withDependencies: {
            $0.surfacedFiles.discard = { url in discarded.withValue { $0.append(url) } }
        }
        await store.send(.agentTapped(hera)) {
            $0.detail = AgentDetail.State(daemon: .dionysus, agent: $0.fleet.agent(self.hera)!, connection: .offline)
        }
        await store.finish()
        #expect(Set(discarded.value) == Set(openPreview.temporaryFiles))
        #expect(discarded.value.count == 2)
    }

    @Test func forgettingTheDaemonDeletesTheOpenPreview() async {
        let discarded = LockIsolated<[URL]>([])
        let store = TestStore(initialState: twoAgentsWithZeusOpen(filesWithPreview(openPreview))) { AppFeature() } withDependencies: {
            $0.surfacedFiles.discard = { url in discarded.withValue { $0.append(url) } }
            $0.secrets.delete = { _ in }
            $0.secrets.load = { _ in nil }
            $0.pushClient.sharePairedDaemons = { _ in }
            $0.pairedDaemons.save = { _ in }
        }
        await store.send(\.daemons.delegate.forget, PairedDaemon.dionysus.id) {
            $0.fleet.sessions.remove(id: PairedDaemon.dionysus.id)
            $0.detail = nil
        }
        await store.finish()
        #expect(Set(discarded.value) == Set(openPreview.temporaryFiles))
    }

    @Test func closingThePreviewDeletesEachOfItsFilesOnce() async {
        let discarded = LockIsolated<[URL]>([])
        let store = TestStore(initialState: twoAgentsWithZeusOpen(filesWithPreview(openPreview))) { AppFeature() } withDependencies: {
            $0.surfacedFiles.discard = { url in discarded.withValue { $0.append(url) } }
        }
        await store.send(\.detail.destination.files.preview.dismiss) {
            $0.detail?.destination?.modify(\.files) { $0.preview = nil }
        }
        await store.finish()
        #expect(discarded.value.sorted { $0.path() < $1.path() } == openPreview.temporaryFiles.sorted { $0.path() < $1.path() })
    }
}
