import AppKit
import GhosttyKit
import Testing

@testable import Ghostty

/// B-072: libghostty builds each new surface's environment from its own
/// copy of the process environment, never from libc's live `environ`.
/// A `setenv` that adds a variable makes libc move `environ` to a bigger
/// block and free the old one; before the fix the next surface read that
/// freed block and crashed the app (the test host died at the first surface
/// opened after `LeoTunnelTestSupport` set its `FAKE_SSH_*` variables).
/// Needs the app's real `Ghostty.App`.
///
/// The surface runs `/bin/cat`, never a shell or a real agent.
@MainActor @Suite(.serialized) struct LeoEnvironSnapshotTests {
    private static let standIn = "/bin/cat"

    /// libc grows `environ` one slot per new variable and moves it to a
    /// bigger block (freeing the old one) once its allocation is full,
    /// usually within a few variables. The cap only bounds the loop.
    private static let maxAddedVariables = 4096

    private static var ghostty: Ghostty.App? { (NSApp.delegate as? AppDelegate)?.ghostty }

    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Adds variables only until libc moves `environ` to a new block, then
    /// removes them at once: the environment is as it was, but not where it
    /// was. The test host is shared and other suites' threads read `environ`
    /// (`ProcessInfo.environment`, `Process` spawns), so the burst stays as
    /// short as the move allows. Returns whether it moved.
    private func reallocateEnviron() -> Bool {
        let before = environ
        var added: [String] = []
        defer { added.forEach { unsetenv($0) } }
        while environ == before, added.count < Self.maxAddedVariables {
            let name = "LEO_B072_\(added.count)"
            setenv(name, "1", 1)
            added.append(name)
        }
        return environ != before
    }

    @Test func aSurfaceSpawnsAfterEnvironIsReallocated() async throws {
        let app = try #require(Self.ghostty?.app, "this test needs the app's Ghostty.App")
        try #require(reallocateEnviron(), "libc moved environ, freeing the block it was in")

        var config = Ghostty.SurfaceConfiguration()
        config.command = Self.standIn
        let view = Ghostty.SurfaceView(app, baseConfig: config)

        #expect(view.surface != nil, "the surface was created, its environment built from libghostty's copy")
        #expect(await eventually { view.surfaceModel?.foregroundPID != nil }, "its process started")
        #expect(!view.processExited)
    }
}
