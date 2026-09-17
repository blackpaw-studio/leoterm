import Foundation

/// Presents the agent picker for a pending `LeoSurfaceRequest` and resolves
/// it via `LeoNewSurfaceRouter.choose(_:for:)`/`chooseDetached(_:for:)`.
/// `LeoWindowPickerRouter` (see `LeoPickerPresentation.swift`) is the real
/// implementation, routing each request to the presenting window's own
/// `LeoPickerPresentation`.
@MainActor protocol LeoPickerPresenting: AnyObject {
    func present(request: LeoSurfaceRequest)
}
