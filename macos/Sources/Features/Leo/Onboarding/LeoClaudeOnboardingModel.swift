import Foundation

/// What the daemon's `/health` says about `claude` (leo ≥ 0.56.2).
enum LeoClaudeHealth: Equatable, Sendable {
    case found(path: String?)
    case missing
    /// An older daemon, an answer without the field, or no answer: the
    /// locator decides.
    case unreported
}

/// The offer's alert, as a seam.
@MainActor protocol LeoClaudeOfferPresenting: AnyObject {
    /// Shows the offer; true when the user chose Set Up. Returns false when withdrawn.
    func presentOffer() async -> Bool
    func withdrawOffer()
    func runSetUp()
}

/// Claude onboarding's decisions. The daemon's `claude.found` leads; the
/// locator is the fallback for a daemon that doesn't report it. The offer
/// is made once per machine at the first live local daemon, again whenever
/// an agent spawn fails with `claude_not_found`, and is withdrawn if claude
/// turns up while it is open.
@MainActor final class LeoClaudeOnboardingModel {
    private let health: () async -> LeoClaudeHealth
    private let locate: () async -> String?
    private let store: LeoClaudeOnboardingStore
    private let presenter: any LeoClaudeOfferPresenting
    private var wasLive = false
    private var isChecking = false
    private var isRechecking = false
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void
    private var lastRecheck: TimeInterval?
    /// Which offer is open, by token: a recheck that outlives its offer
    /// (Not Now clicked mid-await) must not touch a later one.
    private var openOffer: Int?
    /// Rechecks while an offer is open, since an idle daemon sends no snapshots.
    private var poll: Task<Void, Never>?
    private var offerCount = 0

    /// Snapshots and the open offer's own poll recheck at most this often.
    static let recheckInterval: TimeInterval = 2

    init(
        health: @escaping () async -> LeoClaudeHealth, locate: @escaping () async -> String?,
        store: LeoClaudeOnboardingStore, presenter: any LeoClaudeOfferPresenting,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.now = now
        self.sleep = sleep
        self.health = health
        self.locate = locate
        self.store = store
        self.presenter = presenter
    }

    /// Every sidebar snapshot. Only the moment a local daemon becomes live
    /// is checked, so the stream of snapshots costs nothing.
    func snapshotLanded(hasLiveLocalDaemon live: Bool) async {
        let becameLive = live && !wasLive
        wasLive = live
        guard live else { return }
        if openOffer != nil { return await recheckIfDue() }
        guard becameLive, !store.wasOffered, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        switch await health() {
        case .missing:
            await offerFirstRun()
        case .found:
            break
        case .unreported:
            // Remembered either way: the locator may spawn a login shell.
            if await locate() == nil { await offerFirstRun() } else { store.markOffered() }
        }
    }

    /// An agent spawn failed with `claude_not_found`.
    func claudeNotFound() async {
        store.markOffered()
        await offer()
    }

    /// App activation: withdraws the open offer once claude is there.
    func recheckOpenOffer() async {
        guard let offer = openOffer, !isRechecking else { return }
        isRechecking = true
        defer { isRechecking = false }
        lastRecheck = now()
        let isMissing = await isMissing()
        // The user may have answered, or another offer opened, during the await.
        guard openOffer == offer, !isMissing else { return }
        presenter.withdrawOffer()
    }

    // MARK: private

    private func recheckIfDue() async {
        if let lastRecheck, now() - lastRecheck < Self.recheckInterval { return }
        await recheckOpenOffer()
    }

    private func startPolling() {
        poll?.cancel()
        let sleep = sleep
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(Self.recheckInterval) } catch { return }
                await self?.recheckIfDue()
            }
        }
    }

    private func isMissing() async -> Bool {
        switch await health() {
        case .missing: true
        case .found: false
        case .unreported: await locate() == nil
        }
    }

    private func offerFirstRun() async {
        store.markOffered()
        await offer()
    }

    private func offer() async {
        guard openOffer == nil else { return }
        offerCount += 1
        openOffer = offerCount
        startPolling()
        let accepted = await presenter.presentOffer()
        openOffer = nil
        poll?.cancel()
        poll = nil
        if accepted { presenter.runSetUp() }
    }
}
