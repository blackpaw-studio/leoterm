import Foundation
import Testing

@testable import Ghostty

@MainActor struct LeoNewSurfaceRouterTests {
    private let identity = LeoAgentIdentity(host: .local, name: "worker")
    private let origin = LeoWindowID()

    @Test func cancelMakesNoCalls() async {
        let spy = RouterSpy()
        let router = spy.makeRouter()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(request)

        await router.choose(.cancel, for: request)

        #expect(spy.attachCalls.isEmpty)
        #expect(spy.openPlainShellCalls.isEmpty)
        #expect(spy.presentSpawnCalls.isEmpty)
        #expect(spy.onFailureCalls.isEmpty)
    }

    @Test(arguments: [
        LeoSurfaceDisposition.tab,
        .split(.right),
        .window,
        .placeholder
    ])
    func agentChoiceAttachesWithTheRequestDisposition(_ disposition: LeoSurfaceDisposition) async {
        let spy = RouterSpy()
        let router = spy.makeRouter()
        let request = LeoSurfaceRequest(origin: origin, disposition: disposition, splitSourceSurface: UUID())
        router.begin(request)

        await router.choose(.agent(identity), for: request)

        #expect(spy.attachCalls.count == 1)
        #expect(spy.attachCalls.first?.0 == identity)
        #expect(spy.attachCalls.first?.1 == request)
    }

    @Test func plainShellChoiceCallsOpenPlainShellWithTheRequest() async {
        let spy = RouterSpy()
        let router = spy.makeRouter()
        let request = LeoSurfaceRequest(origin: origin, disposition: .placeholder)
        router.begin(request)

        await router.choose(.plainShell, for: request)

        #expect(spy.openPlainShellCalls == [request])
        #expect(spy.attachCalls.isEmpty)
    }

    @Test func placeholderDispositionOpensExactlyOnce() async {
        let spy = RouterSpy()
        let router = spy.makeRouter()
        let request = LeoSurfaceRequest(origin: origin, disposition: .placeholder)
        router.begin(request)

        await router.choose(.agent(identity), for: request)

        #expect(spy.attachCalls.count == 1)
    }

    @Test func placeholderRequestsForDifferentSurfaceIDsDoNotSupersede() async {
        let spy = RouterSpy()
        let router = spy.makeRouter()
        let first = LeoSurfaceRequest(origin: origin, disposition: .placeholder(surfaceID: UUID()))
        let second = LeoSurfaceRequest(origin: origin, disposition: .placeholder(surfaceID: UUID()))
        router.begin(first)
        router.begin(second)

        await router.choose(.agent(identity), for: first)
        await router.choose(.agent(identity), for: second)

        #expect(spy.attachCalls.count == 2)
    }

    @Test func newAgentPresentsSpawnThenAttachesReturnedIdentity() async {
        let spy = RouterSpy()
        let spawned = LeoAgentIdentity(host: .local, name: "spawned")
        spy.spawnResult = spawned
        let router = spy.makeRouter()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(request)

        await router.choose(.newAgent, for: request)

        #expect(spy.presentSpawnCalls == [request])
        #expect(spy.attachCalls.count == 1)
        #expect(spy.attachCalls.first?.0 == spawned)
    }

    @Test func newAgentSpawnCancelledAttachesNothing() async {
        let spy = RouterSpy()
        spy.spawnResult = nil
        let router = spy.makeRouter()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(request)

        await router.choose(.newAgent, for: request)

        #expect(spy.attachCalls.isEmpty)
    }

    @Test func staleSpawnCallbackAfterInvalidateAttachesNothing() async {
        let spy = RouterSpy()
        let spawned = LeoAgentIdentity(host: .local, name: "spawned")
        spy.spawnResult = spawned
        spy.invalidateOriginBeforeSpawnResolves = true
        let router = spy.makeRouter()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(request)

        await router.choose(.newAgent, for: request)

        #expect(spy.attachCalls.isEmpty)
    }

    @Test func staleRequestNotActiveForOriginMakesNoCalls() async {
        let spy = RouterSpy()
        let router = spy.makeRouter()
        let first = LeoSurfaceRequest(origin: origin, disposition: .tab)
        let second = LeoSurfaceRequest(origin: origin, disposition: .window)
        router.begin(first)
        router.begin(second)

        await router.choose(.agent(identity), for: first)

        #expect(spy.attachCalls.isEmpty)
    }

    @Test func invalidatedRequestMakesNoCalls() async {
        let spy = RouterSpy()
        let router = spy.makeRouter()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(request)
        router.invalidate(origin: origin)

        await router.choose(.agent(identity), for: request)

        #expect(spy.attachCalls.isEmpty)
    }

    @Test func invalidRequestPerInjectedValidatorMakesNoCalls() async {
        let spy = RouterSpy()
        spy.isRequestValid = { _ in false }
        let router = spy.makeRouter()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(request)

        await router.choose(.agent(identity), for: request)

        #expect(spy.attachCalls.isEmpty)
    }

    @Test func duplicateChooseForSameRequestIsIgnored() async {
        let spy = RouterSpy()
        let gate = ChooseGate()
        spy.attachGate = gate
        let router = spy.makeRouter()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(request)

        // First call enters `attach` and suspends there (gated); give it a
        // chance to register itself as in-flight before racing a duplicate.
        let firstTask = Task { await router.choose(.agent(identity), for: request) }
        await gate.waitUntilEntered()
        await router.choose(.agent(identity), for: request)
        await gate.releaseFirst()

        // Bounded: if the in-flight guard regresses and both calls reach
        // `attach`, the gate deadlocks (each waits on its own unresumed
        // continuation) and `firstTask` never completes -- fail instead of
        // hanging the suite forever.
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await firstTask.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        await gate.releaseAll()

        #expect(completed, "first choose() never completed -- the duplicate-choose guard likely regressed")
        // The duplicate call for the still-in-flight request must be
        // ignored -- only the first call's attach reaches the fake.
        #expect(spy.attachCalls.count == 1)
    }

    @Test func repeatedChooseAfterSuccessCreatesNothing() async {
        let spy = RouterSpy()
        let router = spy.makeRouter()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(request)

        await router.choose(.agent(identity), for: request)
        #expect(spy.attachCalls.count == 1)

        // The request is retired on success -- a later choose for the same
        // (now stale) request must no-op, not attach again.
        await router.choose(.agent(identity), for: request)
        #expect(spy.attachCalls.count == 1)
    }

    @Test func chooseAfterCancelCreatesNothing() async {
        let spy = RouterSpy()
        let router = spy.makeRouter()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(request)

        await router.choose(.cancel, for: request)
        await router.choose(.agent(identity), for: request)

        #expect(spy.attachCalls.isEmpty)
    }

    @Test func deferredSpawnCompletionAfterSupersessionCreatesNothing() async {
        let spy = RouterSpy()
        spy.spawnResult = LeoAgentIdentity(host: .local, name: "spawned")
        spy.supersedeOriginBeforeSpawnResolves = true
        let router = spy.makeRouter()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(request)

        await router.choose(.newAgent, for: request)

        #expect(spy.attachCalls.isEmpty)
    }

    @Test func attachFailureReportsOnFailureAndRequestStaysActiveForRetry() async {
        let spy = RouterSpy()
        spy.attachResult = .failure(.init(identity: identity, kind: .openFailed("boom")))
        let router = spy.makeRouter()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(request)

        await router.choose(.agent(identity), for: request)
        #expect(spy.onFailureCalls.count == 1)
        #expect(spy.onFailureCalls.first?.0 == request)

        spy.attachResult = .success(())
        await router.choose(.agent(identity), for: request)
        #expect(spy.attachCalls.count == 2)
    }

    /// Review finding: a `.placeholder` request's `isRequestValid` flips to
    /// `false` the instant its tree stops being empty -- i.e. exactly when
    /// the fill *succeeds*. Retiring must not re-check validity after the
    /// fact, or a successful placeholder fill would never retire and a
    /// stale re-`choose` on it would wrongly re-attach.
    @Test func successRetiresEvenWhenNoLongerValidAfterward() async {
        let spy = RouterSpy()
        var checks = 0
        spy.isRequestValid = { _ in
            checks += 1
            return checks == 1
        }
        let router = spy.makeRouter()
        let request = LeoSurfaceRequest(origin: origin, disposition: .placeholder)
        router.begin(request)

        await router.choose(.agent(identity), for: request)
        #expect(spy.attachCalls.count == 1)

        // If retirement were gated on validity, the request would still be
        // "active" here and this would attach again.
        await router.choose(.agent(identity), for: request)
        #expect(spy.attachCalls.count == 1)
    }

    /// Review finding: two same-origin gestures issued back-to-back, before
    /// either's chosen work has actually run, must both create a
    /// destination -- `begin(_:)` superseding the first request must not
    /// retroactively cancel a choice already committed via
    /// `chooseDetached`.
    @Test func chooseDetachedSurvivesASubsequentBeginForTheSameOrigin() async {
        let spy = RouterSpy()
        let router = spy.makeRouter()
        let first = LeoSurfaceRequest(origin: origin, disposition: .tab)
        let second = LeoSurfaceRequest(origin: origin, disposition: .tab)

        router.begin(first)
        #expect(router.chooseDetached(.plainShell, for: first))
        router.begin(second)
        #expect(router.chooseDetached(.plainShell, for: second))

        for _ in 0..<200 where spy.openPlainShellCalls.count < 2 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(spy.openPlainShellCalls == [first, second])
    }

    @Test func onRequestEndedFiresOnCancelSuccessAndUncommittedSupersede() async {
        let spy = RouterSpy()
        var ended: [LeoSurfaceRequest] = []
        spy.onRequestEnded = { ended.append($0) }
        let router = spy.makeRouter()

        let cancelled = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(cancelled)
        await router.choose(.cancel, for: cancelled)

        let succeeded = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(succeeded)
        await router.choose(.agent(identity), for: succeeded)

        let displaced = LeoSurfaceRequest(origin: origin, disposition: .tab)
        router.begin(displaced)
        router.invalidate(origin: origin)

        #expect(ended == [cancelled, succeeded, displaced])
    }
}

@MainActor private final class RouterSpy {
    var attachCalls: [(LeoAgentIdentity, LeoSurfaceRequest)] = []
    var openPlainShellCalls: [LeoSurfaceRequest] = []
    var presentSpawnCalls: [LeoSurfaceRequest] = []
    var onFailureCalls: [(LeoSurfaceRequest, LeoAttachError)] = []

    var attachResult: Result<Void, LeoAttachError> = .success(())
    var openPlainShellResult: Result<Void, LeoAttachError> = .success(())
    var spawnResult: LeoAgentIdentity?
    var isRequestValid: (LeoSurfaceRequest) -> Bool = { _ in true }
    var invalidateOriginBeforeSpawnResolves = false
    var supersedeOriginBeforeSpawnResolves = false
    var attachGate: ChooseGate?
    var onRequestEnded: (LeoSurfaceRequest) -> Void = { _ in }

    private weak var router: LeoNewSurfaceRouter?

    func makeRouter() -> LeoNewSurfaceRouter {
        let router = LeoNewSurfaceRouter(
            attach: { [weak self] identity, request, _ in
                self?.attachCalls.append((identity, request))
                if let gate = self?.attachGate { await gate.enterAndWaitForRelease() }
                return self?.attachResult ?? .success(())
            },
            openPlainShell: { [weak self] request in
                self?.openPlainShellCalls.append(request)
                return self?.openPlainShellResult ?? .success(())
            },
            presentSpawn: { [weak self] request, completion in
                self?.presentSpawnCalls.append(request)
                if self?.invalidateOriginBeforeSpawnResolves == true {
                    self?.router?.invalidate(origin: request.origin)
                }
                if self?.supersedeOriginBeforeSpawnResolves == true {
                    self?.router?.begin(LeoSurfaceRequest(origin: request.origin, disposition: .window))
                }
                completion(self?.spawnResult)
            },
            isRequestValid: { [weak self] request in self?.isRequestValid(request) ?? true },
            onFailure: { [weak self] request, error in self?.onFailureCalls.append((request, error)) },
            onRequestEnded: { [weak self] request in self?.onRequestEnded(request) }
        )
        self.router = router
        return router
    }
}

/// Lets a test observe that an async closure has been entered (and is
/// suspended) before racing a second call against it. Each entrant gets its
/// own continuation slot, so a regression that lets *two* calls enter
/// concurrently doesn't clobber the first entrant's continuation (which
/// would otherwise leak it and hang the test forever) -- `releaseAll()`
/// gives tests a way to unconditionally unstick every entrant afterwards.
private actor ChooseGate {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWaitForRelease() async {
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { pending.append($0) }
    }

    func waitUntilEntered() async {
        guard pending.isEmpty else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func releaseFirst() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume()
    }

    func releaseAll() {
        let all = pending
        pending.removeAll()
        for continuation in all { continuation.resume() }
    }
}
