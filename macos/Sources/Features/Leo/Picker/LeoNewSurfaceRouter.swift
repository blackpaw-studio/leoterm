import Foundation

/// Resolves a picker choice for one in-flight `LeoSurfaceRequest` into a
/// coordinator call, the plain-shell path, or the Spawn Agent sheet followed
/// by attach. Pure routing -- no AppKit, no direct `LeoAttachCoordinator`
/// dependency (injected as closures so it is independently testable).
@MainActor final class LeoNewSurfaceRouter {
    private let attach: (LeoAgentIdentity, LeoSurfaceRequest) async -> Result<Void, LeoAttachError>
    private let openPlainShell: (LeoSurfaceRequest) async -> Result<Void, LeoAttachError>
    private let presentSpawn: (LeoSurfaceRequest, @escaping (LeoAgentIdentity?) -> Void) -> Void
    private let isRequestValid: (LeoSurfaceRequest) -> Bool
    private let onFailure: (LeoSurfaceRequest, LeoAttachError) -> Void

    /// One active request per origin window -- a new `begin(_:)` for the
    /// same origin silently supersedes whatever request was pending there.
    /// A request is retired (removed here) on any terminal, non-retryable
    /// outcome: `.cancel`, or a successful attach/plain-shell/spawn-attach.
    /// It stays active only after a *failed* attach, so the palette can
    /// retry the same request.
    private var activeRequestByOrigin: [LeoWindowID: LeoSurfaceRequest] = [:]
    /// Guards against a duplicate `choose(_:for:)` call for the same
    /// request racing the one already in flight (e.g. a double Return).
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
        onFailure: @escaping (LeoSurfaceRequest, LeoAttachError) -> Void = { _, _ in }
    ) {
        self.attach = attach
        self.openPlainShell = openPlainShell
        self.presentSpawn = presentSpawn
        self.isRequestValid = isRequestValid
        self.onFailure = onFailure
    }

    /// Registers `request` as the active gesture for its origin window,
    /// superseding (and resuming, with `nil`, any pending spawn for)
    /// whatever request was previously active there.
    func begin(_ request: LeoSurfaceRequest) {
        supersede(origin: request.origin)
        activeRequestByOrigin[request.origin] = request
    }

    /// Drops the active request for `origin`, if any (e.g. Esc / window
    /// closed), and resumes its pending spawn completion (if any) with
    /// `nil` so a `choose` suspended on the spawn sheet returns instead of
    /// hanging forever.
    func invalidate(origin: LeoWindowID) {
        supersede(origin: origin)
    }

    func choose(_ choice: LeoPickerChoice, for request: LeoSurfaceRequest) async {
        guard isActive(request), isRequestValid(request) else { return }
        guard inFlightRequestIDs.insert(request.id).inserted else { return }
        defer { inFlightRequestIDs.remove(request.id) }

        switch choice {
        case .cancel:
            retireIfActive(request)
        case .agent(let identity):
            await performAttach(identity: identity, request: request)
        case .plainShell:
            let result = await openPlainShell(request)
            handle(result, request: request)
        case .newAgent:
            let identity = await requestSpawnedIdentity(for: request)
            guard let identity, isActive(request), isRequestValid(request) else { return }
            await performAttach(identity: identity, request: request)
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

    private func performAttach(identity: LeoAgentIdentity, request: LeoSurfaceRequest) async {
        let result = await attach(identity, request)
        handle(result, request: request)
    }

    private func handle(_ result: Result<Void, LeoAttachError>, request: LeoSurfaceRequest) {
        guard isActive(request), isRequestValid(request) else { return }
        switch result {
        case .success:
            retireIfActive(request)
        case .failure(let error):
            onFailure(request, error)
        }
    }

    private func isActive(_ request: LeoSurfaceRequest) -> Bool {
        activeRequestByOrigin[request.origin] == request
    }

    private func retireIfActive(_ request: LeoSurfaceRequest) {
        guard activeRequestByOrigin[request.origin] == request else { return }
        activeRequestByOrigin.removeValue(forKey: request.origin)
    }

    /// Removes the active request for `origin` (if any) and resumes its
    /// pending spawn completion, if one is still outstanding, with `nil`.
    private func supersede(origin: LeoWindowID) {
        guard let previous = activeRequestByOrigin.removeValue(forKey: origin) else { return }
        if let resume = pendingSpawnResumes.removeValue(forKey: previous.id) {
            resume(nil)
        }
    }
}
