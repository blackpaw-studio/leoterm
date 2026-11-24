import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor struct LeoPluginAccountPickerModelTests {
    private static let dionysus = LeoHostID.remote("Dionysus")
    private static let hestia = LeoHostID.remote("Hestia")

    /// Answers each machine's `/credentials/accounts` from a table, or fails like a down socket.
    private actor Daemon: LeoDaemonTransport {
        enum Behavior: Sendable { case accounts(String), notFound, down }
        private(set) var paths: [String] = []
        private let behavior: Behavior
        init(_ behavior: Behavior) { self.behavior = behavior }

        func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
            paths.append(request.path)
            switch behavior {
            case .accounts(let body): return LeoHTTPResponse(status: 200, body: Data(body.utf8))
            case .notFound: return LeoHTTPResponse(status: 404, body: Data("not found".utf8))
            case .down: throw LeoDaemonError.timeout
            }
        }
    }

    private static let mixed = """
    {"accounts":[
      {"kind":"claude-code","dir":"/Users/evan/.claude","label":"default"},
      {"kind":"codex","dir":"/Users/evan/.codex","label":"codex"},
      {"kind":"claude-code","dir":"/Users/evan/.claude-blackpaw-leo","label":"blackpaw-leo"}]}
    """

    private func model(kind: LeoPluginCredentialKind = .claudeCode, _ daemons: [LeoHostID: Daemon]) -> LeoPluginAccountPickerModel {
        LeoPluginAccountPickerModel(
            kind: kind, machines: [.local] + daemons.keys.sorted { $0.displayName < $1.displayName },
            daemon: { host in daemons[host].map { LeoSocketDaemonClient(socketPath: "/tmp/\(host.displayName).sock", transport: $0) } })
    }

    @Test func thisMacComesFirstAndIsSelectedWithNothingToLoad() async {
        let daemon = Daemon(.accounts(Self.mixed))
        let model = model([Self.dionysus: daemon])
        #expect(model.machines == [.local, Self.dionysus])
        #expect(model.machine == .local)
        await model.load()
        #expect(model.accounts == .idle)
        #expect(await daemon.paths.isEmpty)
        #expect(model.choice == .thisMac)
    }

    @Test func aRemoteMachineListsOnlyAccountsOfTheKindBeingAdded() async {
        let daemon = Daemon(.accounts(Self.mixed))
        let model = model([Self.dionysus: daemon])
        await model.select(Self.dionysus)
        #expect(model.accounts == .loaded([
            LeoCredentialAccount(kind: .claudeCode, dir: "/Users/evan/.claude", label: "default"),
            LeoCredentialAccount(kind: .claudeCode, dir: "/Users/evan/.claude-blackpaw-leo", label: "blackpaw-leo"),
        ]))
        #expect(await daemon.paths == ["/credentials/accounts?kind=claude-code"])
    }

    @Test func theChoiceNeedsAnAccountPickedOnTheRemoteMachine() async {
        let model = model([Self.dionysus: Daemon(.accounts(Self.mixed))])
        await model.select(Self.dionysus)
        #expect(model.choice == nil)
        model.selectedDir = "/Users/evan/.claude-blackpaw-leo"
        #expect(model.choice == .remote(Self.dionysus, dir: "/Users/evan/.claude-blackpaw-leo"))
        await model.select(.local)
        #expect(model.choice == .thisMac)
    }

    @Test func switchingMachinesForgetsThePreviousAccount() async {
        let model = model([Self.dionysus: Daemon(.accounts(Self.mixed)), Self.hestia: Daemon(.accounts(Self.mixed))])
        await model.select(Self.dionysus)
        model.selectedDir = "/Users/evan/.claude"
        await model.select(Self.hestia)
        #expect(model.selectedDir == nil)
    }

    @Test func aMachineWithNoLiveConnectionIsOffline() async {
        let model = LeoPluginAccountPickerModel(kind: .codex, machines: [.local, Self.dionysus], daemon: { _ in nil })
        await model.select(Self.dionysus)
        #expect(model.accounts == .failed("Dionysus is offline"))
        #expect(model.choice == nil)
    }

    @Test func anOlderDaemonSaysItCantShareAccounts() async {
        let model = model([Self.dionysus: Daemon(.notFound)])
        await model.select(Self.dionysus)
        #expect(model.accounts == .failed("Dionysus's Leo is too old to share accounts"))
    }

    @Test func aMachineThatTimesOutIsOffline() async {
        let model = model([Self.dionysus: Daemon(.down)])
        await model.select(Self.dionysus)
        #expect(model.accounts == .failed("Dionysus is offline"))
    }

    @Test func aMachineWithNoAccountsOfTheKindSaysSo() async {
        let model = model(kind: .codex, [Self.dionysus: Daemon(.accounts(#"{"accounts":[{"kind":"claude-code","dir":"/d","label":"x"}]}"#))])
        await model.select(Self.dionysus)
        #expect(model.accounts == .loaded([]))
    }
}
