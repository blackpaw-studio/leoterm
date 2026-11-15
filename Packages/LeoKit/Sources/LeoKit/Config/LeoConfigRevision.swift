import Foundation

/// Per machine, which leo.yaml revisions the app's own writes superseded.
///
/// Every pane holds the revision it loaded. When one pane's write comes back
/// as R′, a pane still holding R is not stale in any way that matters: the
/// change was the app's own, to another section. `resolve` maps R to R′ so
/// that pane saves without a spurious conflict. A revision this tracker never
/// saw superseded (an edit by the CLI or the web UI) resolves to itself, and
/// its mismatch stays a real conflict. Panes share one tracker by reference.
public final class LeoConfigRevisionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var successors: [String: String] = [:]

    public init() {}

    /// A write sent with `from` that the daemon answered with `to`.
    public func recordWrite(from: String, to: String) {
        guard from != to else { return }
        lock.withLock { successors[from] = to }
    }

    /// The newest revision known to descend from `revision` through the
    /// app's own writes.
    public func resolve(_ revision: String) -> String {
        lock.withLock {
            var current = revision
            var seen: Set<String> = [revision]
            while let next = successors[current], seen.insert(next).inserted { current = next }
            return current
        }
    }

    /// Forgets every write: after a machine switch or a full reload every
    /// pane holds a fresh revision.
    public func reset() {
        lock.withLock { successors.removeAll() }
    }
}
