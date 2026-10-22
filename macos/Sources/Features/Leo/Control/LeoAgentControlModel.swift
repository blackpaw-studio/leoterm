import AppKit
import Combine
import Foundation
import LeoKit

/// What the control bar says under a row's field: a refused action, or a
/// quiet note that a message was queued.
enum LeoControlFeedback: Equatable, Sendable {
    case error(String)
    case notice(String)
}

/// The state behind the prompt box and its verbs (B-262): a draft per agent
/// row (memory only, not a queue), the one verb in flight per row, inline
/// feedback, and the hosts whose token the daemon refused. Each verb goes
/// to its row's own host's daemon, resolved like `LeoAgentActions`.
@MainActor final class LeoAgentControlModel: ObservableObject {
    /// The daemon's limit on `text` (256 KiB).
    static let maxMessageBytes = 256 * 1024

    @Published private(set) var drafts: [LeoAgentRow.ID: String] = [:]
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

    func draft(for id: LeoAgentRow.ID) -> String { drafts[id] ?? "" }

    func setDraft(_ text: String, for id: LeoAgentRow.ID) {
        guard draft(for: id) != text else { return }
        drafts[id] = text.isEmpty ? nil : text
        feedback[id] = nil
    }

    func dismissFeedback(for id: LeoAgentRow.ID) { feedback[id] = nil }

    func canSendDraft(for id: LeoAgentRow.ID) -> Bool {
        !draft(for: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func retryAfterDenial(host: LeoHostID) {
        deniedHosts.remove(host)
        feedback = feedback.filter { $0.key.host != host }
    }

    func send(_ row: LeoAgentRow) async {
        let sentDraft = draft(for: row.id)
        let text = sentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.utf8.count <= Self.maxMessageBytes else {
            feedback[row.id] = .error("That message is too long (the limit is 256 KiB).")
            return
        }
        guard let delivery = await perform(.message, row, { try await $0.message(row.name, text: text) }) else { return }
        // Only the draft that was sent: anything typed meanwhile stays.
        if draft(for: row.id) == sentDraft { drafts[row.id] = nil }
        if delivery == .queued { feedback[row.id] = .notice("Queued. \(row.name) will get it when it can.") }
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
