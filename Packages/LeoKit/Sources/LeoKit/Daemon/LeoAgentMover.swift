import Foundation

public enum LeoAgentMoveOutcome: Equatable, Sendable {
    case done(LeoMoveResult)
    /// The daemon refused. `message` is its own text (the app's wording for
    /// `agent_busy`); `offersForce` is true only for a mid-turn move.
    case refused(code: String, message: String, offersForce: Bool)
    /// The job can no longer be found (a daemon restart drops finished jobs),
    /// so its outcome is not known.
    case unknown(String)
}

/// Starts a move or copy and follows its job to an outcome. The transport
/// lives behind `LeoDaemonClient.startMove` / `moveJob(id:)`, so a client
/// with a different route reuses this unchanged.
public struct LeoAgentMover: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let client: any LeoMoveJobClient
    private let pollInterval: Duration
    private let sleep: Sleep

    public init(
        client: any LeoMoveJobClient,
        pollInterval: Duration = .seconds(1),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    /// How many polls in a row may be dropped (a transport error or timeout, as
    /// on a slow ssh-forwarded socket during a long copy) before the outcome is
    /// given up as unknown. The move itself carries on in the daemon.
    public static let maxConsecutivePollFailures = 5
    public static let lostContactMessage = "Lost contact with the daemon. The move may still be running; check the agent in a moment."
    /// Backoff doubles per consecutive failure, up to this many doublings.
    private static let maxBackoffDoublings = 4

    /// A refusal at start (`agent_moving`, a transport failure) throws; so does
    /// cancellation, which stops polling and leaves the job running on the daemon.
    public func run(_ name: String, _ request: LeoMoveRequest) async throws -> LeoAgentMoveOutcome {
        var job = try await client.startMove(name, request)
        var failures = 0
        while true {
            if let outcome = Self.outcome(of: job, agent: name) { return outcome }
            try Task.checkCancellation()
            try await sleep(pollInterval * (1 << min(failures, Self.maxBackoffDoublings)))
            do {
                job = try await client.moveJob(id: job.id)
                failures = 0
            } catch LeoDaemonError.daemon(LeoMoveWire.notFoundCode, let message, _) {
                return .unknown(message)
            } catch LeoDaemonError.transport, LeoDaemonError.timeout {
                failures += 1
                if failures >= Self.maxConsecutivePollFailures { return .unknown(Self.lostContactMessage) }
            }
        }
    }

    private static func outcome(of job: LeoMoveJob, agent: String) -> LeoAgentMoveOutcome? {
        switch job.state {
        case .running:
            return nil
        case .done:
            return .done(job.result ?? LeoMoveResult(name: agent))
        case .failed:
            let code = job.error?.code ?? "move_failed"
            let text = job.problems.isEmpty ? job.error?.message ?? "The move failed." : job.problems.map(\.message).joined(separator: "\n")
            // The app's wording of a busy refusal speaks of Force; a busy copy
            // (or a failed busy probe) has no Force, so it keeps the daemon's text.
            let isBusyWithoutForce = code == LeoMoveJob.busyCode && !job.offersForce
            let message = isBusyWithoutForce ? text : LeoDaemonError.daemon(code: code, message: text, matches: []).localizedDescription
            return .refused(code: code, message: message, offersForce: job.offersForce)
        case .unknown(let raw):
            return .unknown("The Leo daemon reported an unexpected move state (\(raw)).")
        }
    }
}
