import Foundation

/// When the sidebar arms a reveal of its selected terminal row (B-149):
/// what a reveal's trigger hands its work to.
struct LeoRevealScheduler {
    let schedule: @MainActor (@escaping @MainActor () -> Void) -> Void

    /// A turn later, once SwiftUI has applied the change that prompted it.
    static var nextTurn: Self { Self { work in DispatchQueue.main.async { work() } } }

    /// Right away, inside the change, before AppKit has laid out anything
    /// it brought: the worst ordering, every time. For tests.
    static var immediate: Self { Self { work in work() } }
}
