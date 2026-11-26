import AppKit

extension Ghostty {
    /// Where `FocusMover` queues a focus move's attempts: right away, or
    /// after `delay` seconds. The app uses the main queue; a test records
    /// the attempts and runs each one when it says so.
    protocol FocusMoveScheduler {
        func schedule(after delay: TimeInterval?, _ work: @escaping () -> Void)
    }

    /// The main queue: `async` for an attempt with no delay, `asyncAfter`
    /// for a retry.
    struct MainQueueFocusMoveScheduler: FocusMoveScheduler {
        func schedule(after delay: TimeInterval?, _ work: @escaping () -> Void) {
            let item = DispatchWorkItem(block: work)
            if let delay {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            } else {
                DispatchQueue.main.async(execute: item)
            }
        }
    }

    /// Moves keyboard focus to a view that may not be in its window yet.
    /// See `Ghostty.moveFocus(to:from:delay:isAllowed:)`, which forwards to
    /// `shared`.
    final class FocusMover {
        static let shared = FocusMover(scheduler: MainQueueFocusMoveScheduler())

        /// Our max delay before we give up.
        static let maxDelay: TimeInterval = 0.5

        /// The first retry's delay; each retry after it doubles it.
        static let firstRetryDelay: TimeInterval = 0.05

        private let scheduler: FocusMoveScheduler

        init(scheduler: FocusMoveScheduler) {
            self.scheduler = scheduler
        }

        func move(
            to: NSView,
            from: NSResponder? = nil,
            delay: TimeInterval? = nil,
            isAllowed: (() -> Bool)? = nil
        ) {
            // The whole delay machinery is a bit of a hack to work around a
            // situation where the window is destroyed and the surface view
            // will never be attached to a window. Realistically, we should
            // handle this upstream but we also don't want this function to be
            // a source of infinite loops.
            guard (delay ?? 0) < Self.maxDelay else { return }

            // We start at a 50 millisecond delay and do a doubling backoff
            let nextDelay: TimeInterval = if let delay {
                delay * 2
            } else {
                Self.firstRetryDelay
            }

            // Weak: a surface that never gets a window (a hidden shell whose
            // window closed) must not be kept alive by the retries (B-378).
            scheduler.schedule(after: delay) { [weak self, weak to, weak from] in
                guard let self, let to else { return }

                // Asked when the move runs, retries included, not when it was
                // queued: what should hold focus can change in between.
                if let isAllowed, !isAllowed() { return }

                // If the callback runs before the surface is attached to a view
                // then the window will be nil. We just reschedule in that case.
                guard let window = to.window else {
                    self.move(to: to, from: from, delay: nextDelay, isAllowed: isAllowed)
                    return
                }

                // If we had a previously focused node and its not where we're sending
                // focus, make sure that we explicitly tell it to lose focus. In theory
                // we should NOT have to do this but the focus callback isn't getting
                // called for some reason.
                if let from {
                    _ = from.resignFirstResponder()
                }

                window.makeFirstResponder(to)
            }
        }
    }
}
