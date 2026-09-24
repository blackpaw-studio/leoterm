import AppKit
import Testing

@testable import Ghostty

/// Exercises `GhosttyAttachTabHost.fillPlaceholder`'s per-leaf (non-nil
/// `surfaceID`) branch against a real `TerminalController` -- there is no
/// lighter-weight fixture for this host, since it drives real AppKit
/// windows and `Ghostty.SurfaceView`s. Requires the app's real `Ghostty.App`
/// (via `AppDelegate`), which is why these tests bail out (rather than
/// fail) when that isn't available.
@MainActor struct GhosttyAttachTabHostRebirthTests {
    private func makeDefaults() -> UserDefaults {
        LeoInMemoryDefaults()
    }

    /// Everything `makeFilledPlaceholder()` needs to hand back to a test:
    /// the host under test, the real controller it's driving, the origin to
    /// pass on the next `fillPlaceholder` call, and the handle the initial
    /// fill produced.
    private struct FilledPlaceholder {
        let host: GhosttyAttachTabHost
        let controller: TerminalController
        let origin: LeoWindowID
        let firstHandle: AttachmentHandle
    }

    /// Builds a placeholder window and fills its (whole-window) empty tree
    /// once to get an initial live leaf, returning everything needed to
    /// drive a second, per-leaf `fillPlaceholder` call against that leaf --
    /// the rebirth path under test.
    private func makeFilledPlaceholder() throws -> FilledPlaceholder? {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else {
            return nil
        }
        let controller = TerminalController.leoNewPlaceholderWindow(ghostty)
        let registry = LeoWindowSessionRegistry()
        let session = registry.makeSession(window: controller.window, controller: controller, defaults: makeDefaults())
        let host = GhosttyAttachTabHost(registry: registry, requestConfigStore: LeoRequestConfigStore())
        let firstHandle = try host.fillPlaceholder(
            command: "", workingDirectory: nil, origin: session.id, surfaceID: nil, requestID: UUID()
        )
        return FilledPlaceholder(host: host, controller: controller, origin: session.id, firstHandle: firstHandle)
    }

    /// Fix 1 (undo resurrection): filling a per-leaf placeholder must not
    /// register a new undo action -- doing so (as `replaceSurfaceTree`
    /// always does) would let "undo" restore the old tree and resurrect the
    /// dead `oldView` into a live split. `undoManager` here is
    /// `AppDelegate`'s single app-wide `ExpiringUndoManager` (every window's
    /// `windowWillReturnUndoManager` returns the same instance), so its
    /// aggregate `canUndo` is contaminated by whatever other windows/tests
    /// have pending in the same process and isn't a reliable signal on its
    /// own. What IS reliable, and what actually matters, is what the most
    /// recently registered action does: chose "perform an actual `undo()`
    /// and check `oldView` is not back in the tree" over inspecting
    /// `ExpiringUndoManager` internals (not introspectable) or `canUndo`
    /// (unreliable here) -- this is expressible against the real
    /// `NSUndoManager` API and directly pins the resurrection bug. Existing
    /// actions targeting `controller` are cleared first so a stale "New
    /// Window" undo from the initial fill can't itself land on top of the
    /// stack and produce a false pass.
    @Test func rebirthOfLeafPlaceholderRegistersNoUndoAction() throws {
        guard let placeholder = try makeFilledPlaceholder() else {
            return
        }
        let controller = placeholder.controller
        defer { controller.window?.close() }

        guard let oldView = controller.surfaceTree.first(where: { $0.id == placeholder.firstHandle.surfaceID }) else {
            Issue.record("expected the first fill's surface to be in the tree")
            return
        }
        controller.undoManager?.removeAllActions(withTarget: controller)

        _ = try placeholder.host.fillPlaceholder(
            command: "", workingDirectory: nil, origin: placeholder.origin,
            surfaceID: placeholder.firstHandle.surfaceID, requestID: UUID()
        )

        controller.undoManager?.undo()
        #expect(!controller.surfaceTree.contains(oldView))
    }

    /// Fix 2 (lifecycle leak): filling a per-leaf placeholder must close the
    /// handle it replaces through the canonical path -- the only one that
    /// yields `.closed` on `lifecycleEvents` -- rather than dropping it from
    /// `attachments` directly.
    @Test func rebirthOfLeafPlaceholderYieldsClosedForTheReplacedHandle() async throws {
        guard let placeholder = try makeFilledPlaceholder() else {
            return
        }
        let (host, firstHandle) = (placeholder.host, placeholder.firstHandle)
        defer { placeholder.controller.window?.close() }

        let secondHandle = try host.fillPlaceholder(
            command: "", workingDirectory: nil, origin: placeholder.origin,
            surfaceID: firstHandle.surfaceID, requestID: UUID()
        )

        let box = OneShotBox<AttachLifecycleEvent?>()
        Task {
            for await event in host.lifecycleEvents where event == .closed(firstHandle) {
                await box.resume(event)
                return
            }
            await box.resume(nil)
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await box.resume(nil)
        }
        let event = await box.wait()

        #expect(event == .closed(firstHandle))
        #expect(host.isOpen(secondHandle))
    }
}

/// One-shot continuation box: whichever of a real result or a timeout
/// arrives first wins, and the loser is a safe no-op. Used instead of
/// `withTaskGroup` so an unstructured (never-terminating) `AsyncStream`
/// consumer can never block the test on teardown.
private actor OneShotBox<T: Sendable> {
    private var continuation: CheckedContinuation<T, Never>?
    private var pending: T?
    private var didResume = false

    func wait() async -> T {
        await withCheckedContinuation { continuation in
            if let pending {
                continuation.resume(returning: pending)
                didResume = true
            } else {
                self.continuation = continuation
            }
        }
    }

    func resume(_ value: T) {
        guard !didResume else { return }
        didResume = true
        if let continuation {
            continuation.resume(returning: value)
        } else {
            pending = value
        }
    }
}
