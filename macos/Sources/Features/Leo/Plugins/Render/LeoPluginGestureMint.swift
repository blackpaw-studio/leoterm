import Foundation
import LeoKit

/// What a renderer calls when a person picks an action. `gesture` is the
/// click or key press that triggered it; the receiver (the slot's action
/// executor) runs it through `LeoPluginActionGate`. Renderers never talk to
/// the daemon themselves.
typealias LeoPluginActionHandler = @MainActor (LeoPluginAction, LeoPluginGesture?) -> Void

/// Mints `LeoPluginGesture` tokens. Only the renderers' click and key paths
/// hold one of these, so nothing decoded from plugin output can become a
/// gesture. The clock is injected so tests don't depend on wall time.
struct LeoPluginGestureMint: Sendable {
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    func mint(_ origin: LeoPluginGesture.Origin) -> LeoPluginGesture {
        LeoPluginGesture(origin: origin, mintedAt: now())
    }
}

/// Bundles the handler and the mint so each view takes one dependency.
struct LeoPluginActionEmitter {
    let mint: LeoPluginGestureMint
    let handler: LeoPluginActionHandler

    @MainActor func emit(_ action: LeoPluginAction, origin: LeoPluginGesture.Origin) {
        handler(action, mint.mint(origin))
    }
}
