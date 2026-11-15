import AppKit

/// Runs the location check once at launch and keeps the sidebar banner in
/// step with it. B5's startup integration reads `state` before it starts any
/// managed setup.
@MainActor final class LeoAppLocationController {
    private(set) var state: LeoAppLocationState = .allowed
    private weak var model: LeoSidebarModel?
    private let environment: LeoLiveMoverEnvironment
    /// The first check's answer for B5; nil inside means "moving, quitting".
    private var resolution: LeoAppLocation??
    private var resolutionWaiters: [CheckedContinuation<LeoAppLocation?, Never>] = []

    init(instanceClaim: LeoSingleInstance.Claim) {
        environment = LeoLiveMoverEnvironment(instanceClaim: instanceClaim)
    }

    /// The pending launch-and-trash that `AppDelegate`'s quit hooks drive.
    var handoff: LeoMoveHandoffCoordinator { environment.handoff }

    func start(model: LeoSidebarModel, bundleURL: URL = Bundle.main.bundleURL, buildKind: LeoBuildKind = .current) {
        self.model = model
        model.moveToApplicationsRequested = { [weak self] in
            Task { @MainActor in await self?.run(bundleURL: bundleURL, buildKind: buildKind) }
        }
        Task { @MainActor in await run(bundleURL: bundleURL, buildKind: buildKind) }
    }

    /// Where the app runs once the launch check has finished (asking to
    /// move first if needed); nil when it is moving itself and quitting.
    func resolvedLocation() async -> LeoAppLocation? {
        if let resolution { return resolution }
        return await withCheckedContinuation { resolutionWaiters.append($0) }
    }

    private func run(bundleURL: URL, buildKind: LeoBuildKind) async {
        let isReadOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let location = LeoAppLocation.decide(bundleURL: bundleURL, buildKind: buildKind, isOnReadOnlyVolume: isReadOnly)
        let gate = LeoAppLocationGate(
            location: location,
            mover: LeoAppMover(environment: environment),
            bundleURL: bundleURL,
            confirmMove: LeoMovePrompt.confirm(reason:)
        )
        state = await gate.run()
        model?.appLocationBanner = state.banner
        resolve(location)
    }

    private func resolve(_ location: LeoAppLocation) {
        guard resolution == nil else { return }
        let resolved = state.resolvedLocation(location)
        resolution = .some(resolved)
        resolutionWaiters.forEach { $0.resume(returning: resolved) }
        resolutionWaiters = []
    }
}
