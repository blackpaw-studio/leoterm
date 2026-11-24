import Foundation
import LeoKit

/// What the Add Account sheet picks: a folder on this Mac (chosen next, in the
/// folder panel), or one of a connected machine's own accounts.
enum LeoPluginAccountChoice: Equatable {
    case thisMac
    case remote(LeoHostID, dir: String)
}

/// The Add Account sheet's state: which machine, and for a remote one, the
/// accounts its daemon offers for the kind being added. Nothing here reads a
/// token; the daemon only names the folders it knows.
@MainActor final class LeoPluginAccountPickerModel: ObservableObject {
    enum Accounts: Equatable {
        case idle
        case loading
        case loaded([LeoCredentialAccount])
        case failed(String)
    }

    let kind: LeoPluginCredentialKind
    /// "This Mac" first, then each connected machine.
    let machines: [LeoHostID]
    @Published private(set) var machine: LeoHostID = .local
    @Published private(set) var accounts: Accounts = .idle
    @Published var selectedDir: String?
    private let daemon: (LeoHostID) -> (any LeoDaemonClient)?

    init(kind: LeoPluginCredentialKind, machines: [LeoHostID], daemon: @escaping (LeoHostID) -> (any LeoDaemonClient)?) {
        self.kind = kind
        self.machines = machines
        self.daemon = daemon
    }

    /// Nil until a remote machine's account is picked.
    var choice: LeoPluginAccountChoice? {
        if machine == .local { return .thisMac }
        return selectedDir.map { .remote(machine, dir: $0) }
    }

    func select(_ host: LeoHostID) async {
        machine = host
        selectedDir = nil
        await load()
    }

    /// Lists the current machine's accounts. A result for a machine the person has since left is dropped.
    func load() async {
        let host = machine
        guard host != .local else { return accounts = .idle }
        guard let client = daemon(host) else { return accounts = .failed("\(host.displayName) is offline") }
        accounts = .loading
        let result: Accounts
        do {
            result = .loaded(try await client.credentialAccounts(kind: kind).filter { $0.kind == kind })
        } catch {
            result = .failed(Self.message(for: error, machine: host.displayName))
        }
        guard machine == host else { return }
        accounts = result
    }

    private static func message(for error: any Error, machine: String) -> String {
        switch error {
        case let remote as LeoCredentialRemoteError: remote.message
        case LeoDaemonError.daemon(code: "not_found", _, _): "\(machine)'s Leo is too old to share accounts"
        case LeoDaemonError.decoding: "\(machine) sent an unexpected reply"
        default: "\(machine) is offline"
        }
    }
}
