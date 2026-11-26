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
    ///
    /// Within one window the newest move that has landed wins (B-447):
    /// moves are numbered as they are asked for, and a retry keeps its
    /// move's number. An attempt that finds its window drops itself if that
    /// window already took a newer move, so an older move still retrying
    /// never takes focus back from it. Windows are ordered apart, and the
    /// check is made where the attempt lands: a view may have no window when
    /// the move is asked for.
    ///
    /// Accepted gaps: a move `isAllowed` refuses (chat covering the
    /// terminal) and focus set outside `moveFocus` (a click, the sidebar's
    /// own `makeFirstResponder`) leave no number, so an older pending move
    /// can still land after them, as before.
    final class FocusMover {
        static let shared = FocusMover(scheduler: MainQueueFocusMoveScheduler())

        /// Our max delay before we give up.
        static let maxDelay: TimeInterval = 0.5

        /// The first retry's delay; each retry after it doubles it.
        static let firstRetryDelay: TimeInterval = 0.05

        private let scheduler: FocusMoveScheduler

        /// The number the latest move was given.
        private var latestMove: UInt64 = 0

        /// The number of the newest move each window took. Weak keys: a
        /// window's entry goes with it.
        private let newestLanded = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()

        init(scheduler: FocusMoveScheduler) {
            self.scheduler = scheduler
        }

        func move(
            to: NSView,
            from: NSResponder? = nil,
            delay: TimeInterval? = nil,
            isAllowed: (() -> Bool)? = nil
        ) {
            latestMove += 1
            attempt(to: to, from: from, delay: delay, isAllowed: isAllowed, moveNumber: latestMove)
        }

        private func attempt(
            to: NSView,
            from: NSResponder?,
            delay: TimeInterval?,
            isAllowed: (() -> Bool)?,
            moveNumber: UInt64
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
                    self.attempt(to: to, from: from, delay: nextDelay, isAllowed: isAllowed, moveNumber: moveNumber)
                    return
                }

                // A newer move already landed in this window: this one is stale.
                if let newest = self.newestLanded.object(forKey: window)?.uint64Value, newest > moveNumber { return }

                // If we had a previously focused node and its not where we're sending
                // focus, make sure that we explicitly tell it to lose focus. In theory
                // we should NOT have to do this but the focus callback isn't getting
                // called for some reason.
                if let from {
                    _ = from.resignFirstResponder()
                }

                if window.makeFirstResponder(to) {
                    self.newestLanded.setObject(NSNumber(value: moveNumber), forKey: window)
                }
            }
        }
    }
}
