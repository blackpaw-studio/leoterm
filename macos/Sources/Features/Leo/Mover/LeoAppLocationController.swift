import AppKit

/// Runs the location check once at launch and keeps the sidebar banner in
/// step with it. B5's startup integration reads `state` before it starts any
/// managed setup.
@MainActor final class LeoAppLocationController {
    private(set) var state: LeoAppLocationState = .allowed
    private weak var model: LeoSidebarModel?
    private let environment: LeoLiveMoverEnvironment

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

    private func run(bundleURL: URL, buildKind: LeoBuildKind) async {
        let isReadOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let gate = LeoAppLocationGate(
            location: .decide(bundleURL: bundleURL, buildKind: buildKind, isOnReadOnlyVolume: isReadOnly),
            mover: LeoAppMover(environment: environment),
            bundleURL: bundleURL,
            confirmMove: LeoMovePrompt.confirm(reason:)
        )
        state = await gate.run()
        model?.appLocationBanner = state.banner
    }
}
