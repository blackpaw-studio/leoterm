import Foundation
import OSLog

/// Resolves a picker choice for one in-flight `LeoSurfaceRequest` into a
/// coordinator call, the plain-shell path, or the Spawn Agent sheet followed
/// by attach. Pure routing -- no AppKit, no direct `LeoAttachCoordinator`
/// dependency (injected as closures so it is independently testable).
@MainActor final class LeoNewSurfaceRouter {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    private let attach: (LeoAgentIdentity, LeoSurfaceRequest) async -> Result<Void, LeoAttachError>
    private let openPlainShell: (LeoSurfaceRequest) async -> Result<Void, LeoAttachError>
    private let presentSpawn: (LeoSurfaceRequest, @escaping (LeoAgentIdentity?) -> Void) -> Void
    private let isRequestValid: (LeoSurfaceRequest) -> Bool
    private let onFailure: (LeoSurfaceRequest, LeoAttachError) -> Void
    /// Called whenever a request stops being tracked -- retired (cancel /
    /// success) or displaced (superseded / invalidated) -- so callers that
    /// key side state off a request's id (e.g. `LeoRequestConfigStore`)
    /// have exactly one place to clean it up.
    private let onRequestEnded: (LeoSurfaceRequest) -> Void

    /// One active request per destination target -- a new `begin(_:)` for the
    /// same origin silently supersedes whatever request was pending there.
    /// A request is retired (removed here) on any terminal, non-retryable
    /// outcome: `.cancel`, or a successful attach/plain-shell/spawn-attach.
    /// It stays active only after a *failed* attach, so the palette can
    /// retry the same request.
    private var activeRequestByTarget: [LeoSurfaceRequestTarget: LeoSurfaceRequest] = [:]
    /// Guards against a duplicate `choose(_:for:)` call for the same
    /// request racing the one already in flight (e.g. a double Return).
    /// Also the "has this request already been committed to a choice"
    /// marker: once inserted here, a later `begin(_:)` for the same origin
    /// no longer affects this request's in-flight work (see `commit(_:)`).
    private var inFlightRequestIDs: Set<UUID> = []
    /// The still-unresumed spawn-sheet completion for a request awaiting
    /// `presentSpawn`, keyed by request id. Consumed (removed) by whichever
    /// happens first: the presenter's callback, or this request being
    /// superseded/invalidated -- so a late or missing presenter callback
    /// can never double-resume the continuation or leave `choose` hung.
    private var pendingSpawnResumes: [UUID: (LeoAgentIdentity?) -> Void] = [:]

    init(
        attach: @escaping (LeoAgentIdentity, LeoSurfaceRequest) async -> Result<Void, LeoAttachError>,
        openPlainShell: @escaping (LeoSurfaceRequest) async -> Result<Void, LeoAttachError>,
        presentSpawn: @escaping (LeoSurfaceRequest, @escaping (LeoAgentIdentity?) -> Void) -> Void,
        isRequestValid: @escaping (LeoSurfaceRequest) -> Bool = { _ in true },
        onFailure: @escaping (LeoSurfaceRequest, LeoAttachError) -> Void = { _, _ in },
        onRequestEnded: @escaping (LeoSurfaceRequest) -> Void = { _ in }
    ) {
        self.attach = attach
        self.openPlainShell = openPlainShell
        self.presentSpawn = presentSpawn
        self.isRequestValid = isRequestValid
        self.onFailure = onFailure
        self.onRequestEnded = onRequestEnded
    }

    /// Registers `request` as the active gesture for its origin window,
    /// superseding (and resuming, with `nil`, any pending spawn for)
    /// whatever request was previously active there. A request already
    /// committed to a choice (see `commit(_:)`) is unaffected -- its
    /// in-flight work runs to completion regardless of what `begin(_:)` is
    /// called afterwards for the same origin.
    func begin(_ request: LeoSurfaceRequest) {
        supersede(target: request.routingTarget)
        activeRequestByTarget[request.routingTarget] = request
    }

    /// Drops the active request for `origin`, if any (e.g. Esc / window
    /// closed), and resumes its pending spawn completion (if any) with
    /// `nil` so a `choose` suspended on the spawn sheet returns instead of
    /// hanging forever.
    func invalidate(origin: LeoWindowID) {
        for target in activeRequestByTarget.keys.filter({ $0.windowID == origin }) { supersede(target: target) }
    }

    func choose(_ choice: LeoPickerChoice, for request: LeoSurfaceRequest) async {
        guard commit(request) else { return }
        defer { release(request) }
        await perform(choice, for: request)
    }

    /// Synchronous variant of `choose(_:for:)`: commits to `choice` for
    /// `request` immediately (before this call returns) if it's still
    /// active and valid, then performs the actual work in a detached
    /// `Task`. Returns `true` if the request was committed.
    ///
    /// Exists because a caller that fires-and-forgets `choose` via its own
    /// `Task { await router.choose(...) }` leaves a gap between that `Task`
    /// being *scheduled* and actually *running* -- a second `begin(_:)` for
    /// the same origin in that gap
    /// would supersede the first request before its choice was ever
    /// committed, silently dropping it. Calling `chooseDetached` instead
    /// commits synchronously, so supersession can only ever displace a
    /// request nothing has been decided for yet.
    @discardableResult
    func chooseDetached(_ choice: LeoPickerChoice, for request: LeoSurfaceRequest) -> Bool {
        guard commit(request) else { return false }
        Task { [weak self] in
            await self?.perform(choice, for: request)
            self?.release(request)
        }
        return true
    }

    /// Validity and in-flight checks happen here, once, before any work
    /// begins -- not re-checked afterwards (see `settle(_:request:)`),
    /// since re-validating post-hoc (e.g. a `.placeholder` request is no
    /// longer "valid" the instant its tree stops being empty, which is the
    /// desired *outcome* of filling it) would wrongly treat success as if
    /// the request had been displaced.
    private func commit(_ request: LeoSurfaceRequest) -> Bool {
        guard isActive(request), isRequestValid(request) else { return false }
        return inFlightRequestIDs.insert(request.id).inserted
    }

    private func release(_ request: LeoSurfaceRequest) {
        inFlightRequestIDs.remove(request.id)
    }

    private func perform(_ choice: LeoPickerChoice, for request: LeoSurfaceRequest) async {
        switch choice {
        case .cancel:
            Self.logger.log("requestOutcome id=\(request.id.uuidString, privacy: .public) outcome=cancel")
            retireIfActive(request)
        case .agent(let identity):
            let result = await attach(identity, request)
            settle(result, request: request)
        case .plainShell:
            let result = await openPlainShell(request)
            settle(result, request: request)
        case .newAgent:
            guard let identity = await requestSpawnedIdentity(for: request) else { return }
            let result = await attach(identity, request)
            settle(result, request: request)
        }
    }

    private func requestSpawnedIdentity(for request: LeoSurfaceRequest) async -> LeoAgentIdentity? {
        await withCheckedContinuation { continuation in
            pendingSpawnResumes[request.id] = { identity in
                continuation.resume(returning: identity)
            }
            presentSpawn(request) { [weak self] identity in
                guard let self, let resume = self.pendingSpawnResumes.removeValue(forKey: request.id) else { return }
                resume(identity)
            }
        }
    }

    /// Settles the outcome of a committed request's work: retires
    /// unconditionally on success (see `commit(_:)`'s doc for why this
    /// must not re-check `isRequestValid`), or reports failure and leaves
    /// the request active so the palette can retry it.
    private func settle(_ result: Result<Void, LeoAttachError>, request: LeoSurfaceRequest) {
        switch result {
        case .success:
            Self.logger.log("requestOutcome id=\(request.id.uuidString, privacy: .public) outcome=success")
            retireIfActive(request)
        case .failure(let error):
            Self.logger.log("requestOutcome id=\(request.id.uuidString, privacy: .public) outcome=failure message=\(error.message, privacy: .public)")
            onFailure(request, error)
        }
    }

    private func isActive(_ request: LeoSurfaceRequest) -> Bool {
        activeRequestByTarget[request.routingTarget] == request
    }

    private func retireIfActive(_ request: LeoSurfaceRequest) {
        guard activeRequestByTarget[request.routingTarget] == request else { return }
        activeRequestByTarget.removeValue(forKey: request.routingTarget)
        onRequestEnded(request)
    }

    /// Removes the active request for `origin` (if any) and resumes its
    /// pending spawn completion (if one is still outstanding) with `nil`.
    /// Only reports the request as ended if it was never committed to a
    /// choice (`commit(_:)`) -- a request already in flight (e.g. awaiting
    /// `attach`) keeps running after being displaced here (see
    /// `chooseDetached`'s doc), so ending it now would be premature: its
    /// own `retireIfActive` call once `perform` settles is what actually
    /// reports it (on success; a failure leaves it retryable and its
    /// config-store entry intact).
    private func supersede(target: LeoSurfaceRequestTarget) {
        guard let previous = activeRequestByTarget.removeValue(forKey: target) else { return }
        if let resume = pendingSpawnResumes.removeValue(forKey: previous.id) {
            resume(nil)
        }
        guard !inFlightRequestIDs.contains(previous.id) else { return }
        Self.logger.log("requestOutcome id=\(previous.id.uuidString, privacy: .public) outcome=superseded")
        onRequestEnded(previous)
    }
}
