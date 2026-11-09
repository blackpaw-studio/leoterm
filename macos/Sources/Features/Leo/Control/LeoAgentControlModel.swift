import AppKit
import Combine
import Foundation
import LeoKit

/// What a control verb says about a row: a refused action, or a quiet note.
enum LeoControlFeedback: Equatable, Sendable {
    case error(String)
    case notice(String)
}

/// The state behind the agent verbs (B-262): the one verb in flight per row,
/// inline feedback, and the hosts whose token the daemon refused. Each verb goes
/// to its row's own host's daemon, resolved like `LeoAgentActions`.
@MainActor final class LeoAgentControlModel: ObservableObject {
    @Published private(set) var inFlight: [LeoAgentRow.ID: LeoControlVerb] = [:]
    @Published private(set) var feedback: [LeoAgentRow.ID: LeoControlFeedback] = [:]
    /// Hosts whose token got a 401/403: controls stay off until a manual
    /// Retry (principle 5: no auto re-probe).
    @Published private(set) var deniedHosts: Set<LeoHostID> = []

    private let clients: any LeoMachineClientResolving
    private var confirmingClear: Set<LeoAgentRow.ID> = []
    private let confirmClear: @MainActor (LeoAgentRow, NSWindow?) async -> Bool

    init(clients: any LeoMachineClientResolving, confirmClear: @escaping @MainActor (LeoAgentRow, NSWindow?) async -> Bool) {
        self.clients = clients
        self.confirmClear = confirmClear
    }

    func dismissFeedback(for id: LeoAgentRow.ID) { feedback[id] = nil }

    func retryAfterDenial(host: LeoHostID) {
        deniedHosts.remove(host)
        feedback = feedback.filter { $0.key.host != host }
    }

    func interrupt(_ row: LeoAgentRow) async { _ = await perform(.interrupt, row) { try await $0.interrupt(row.name) } }

    func compact(_ row: LeoAgentRow) async { _ = await perform(.compact, row) { try await $0.compact(row.name, instructions: nil) } }

    func clear(_ row: LeoAgentRow, in window: NSWindow? = nil) async {
        guard inFlight[row.id] == nil, !deniedHosts.contains(row.host), confirmingClear.insert(row.id).inserted else { return }
        defer { confirmingClear.remove(row.id) }
        guard await confirmClear(row, window) else { return }
        // The sheet was up a while: re-check, and say so rather than drop a confirmed Clear.
        if deniedHosts.contains(row.host) {
            feedback[row.id] = .error(LeoAgentControlAvailability.deniedMessage)
            return
        }
        guard inFlight[row.id] == nil else {
            feedback[row.id] = .error("Another action is running. Try Clear again when it finishes.")
            return
        }
        _ = await perform(.clear, row) { try await $0.clear(row.name) }
    }

    /// Runs one verb for `row`. Nil means it did not succeed (or was not
    /// attempted); a failure is already on the row's feedback.
    private func perform<T: Sendable>(
        _ verb: LeoControlVerb, _ row: LeoAgentRow, _ operation: @Sendable (any LeoDaemonClient) async throws -> T
    ) async -> T? {
        guard inFlight[row.id] == nil, !deniedHosts.contains(row.host) else { return nil }
        guard let daemon = clients.daemon(for: row.host) else {
            feedback[row.id] = .error("\(row.host.displayName) isn't connected.")
            return nil
        }
        inFlight[row.id] = verb
        feedback[row.id] = nil
        defer { inFlight[row.id] = nil }
        do {
            // A success belongs to its own row (ids include the host), so it counts after a reconnect.
            return try await operation(daemon)
        } catch {
            // Keyed by row and host, so a late failure lands on its own row even after a reconnect.
            fail(error, row)
            return nil
        }
    }

    private func fail(_ error: Error, _ row: LeoAgentRow) {
        if case LeoDaemonError.daemon(let code, _, _) = error, code == "unauthorized" || code == "forbidden" {
            deniedHosts.insert(row.host)
        }
        feedback[row.id] = .error(error.localizedDescription)
    }
}
