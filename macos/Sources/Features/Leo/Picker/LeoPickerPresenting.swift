import Foundation

/// Presents the agent picker for a pending `LeoSurfaceRequest` and resolves
/// it via `LeoNewSurfaceRouter.choose(_:for:)`. `LeoAgentPalettePanel` (Task
/// 3) will show the real floating palette; until then every gesture is
/// wired through `LeoPassthroughPicker` below.
@MainActor protocol LeoPickerPresenting: AnyObject {
    func present(request: LeoSurfaceRequest)
}

/// Temporary stand-in for the real agent palette (Task 3). Immediately
/// resolves every request to `.plainShell` so intercepting new-surface
/// gestures (Task 2) does not change today's behaviour: Cmd+T / Cmd+D /
/// Cmd+N still land on a plain Ghostty surface, just routed through the
/// picker plumbing instead of created directly.
@MainActor final class LeoPassthroughPicker: LeoPickerPresenting {
    private let router: LeoNewSurfaceRouter

    init(router: LeoNewSurfaceRouter) {
        self.router = router
    }

    func present(request: LeoSurfaceRequest) {
        // `chooseDetached` (not `Task { await router.choose(...) }`)
        // commits the choice synchronously -- see its doc for why that
        // matters for two same-origin gestures issued back-to-back.
        router.chooseDetached(.plainShell, for: request)
    }
}
