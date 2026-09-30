import AppKit
import Testing

@testable import Ghostty

/// B-052 against a real `TerminalController`: an attach surface's window
/// title is its agent's name, following the focused split; Change Tab
/// Title… still wins; other surfaces keep Ghostty's own title. Needs the
/// app's real `Ghostty.App`, so these bail out (rather than fail) without it.
@MainActor struct LeoTitleIntegrationTests {
    private struct Fixture {
        let host: GhosttyAttachContentHost
        let controller: TerminalController
        let origin: LeoWindowID
        let handle: AttachmentHandle

        var window: NSWindow? { controller.window }

        func surface(_ handle: AttachmentHandle) -> Ghostty.SurfaceView? {
            controller.surfaceTree.first { $0.id == handle.surfaceID }
        }

        /// What `TerminalView` reports when the user focuses `handle`'s split.
        func focus(_ handle: AttachmentHandle) {
            controller.focusedSurfaceDidChange(to: surface(handle))
        }
    }

    /// A start-screen window filled once with a plain shell (no agent yet).
    private func makeFixture() throws -> Fixture? {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return nil }
        let controller = TerminalController.leoNewPlaceholderWindow(ghostty)
        let registry = LeoWindowSessionRegistry()
        let session = registry.makeSession(window: controller.window, controller: controller, defaults: LeoInMemoryDefaults())
        let host = GhosttyAttachContentHost(registry: registry, requestConfigStore: LeoRequestConfigStore())
        let handle = try host.fillPlaceholder(command: "", workingDirectory: nil, origin: session.id, surfaceID: nil, requestID: UUID())
        let fixture = Fixture(host: host, controller: controller, origin: session.id, handle: handle)
        fixture.focus(handle)
        return fixture
    }

    /// Lets `SurfaceView.setTitle`'s coalescing timer fire.
    private func settleTitle() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    /// Until the terminal (or Ghostty's 0.5 s 👻 fallback) titles `surface`.
    private func waitForTerminalTitle(_ surface: Ghostty.SurfaceView) async {
        let deadline = Date().addingTimeInterval(2)
        while surface.title.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func attachSurfaceIsTitledWithTheAgentName() throws {
        guard let fixture = try makeFixture() else { return }
        defer { fixture.window?.close() }

        fixture.host.setAgentName(fixture.handle, name: "autopilot-scratch")

        #expect(fixture.window?.title == "autopilot-scratch")
    }

    @Test func terminalSetTitleDoesNotReplaceTheAgentName() async throws {
        guard let fixture = try makeFixture() else { return }
        defer { fixture.window?.close() }
        fixture.host.setAgentName(fixture.handle, name: "autopilot-scratch")

        fixture.surface(fixture.handle)?.setTitle("👻 Ghostty")
        await settleTitle()

        #expect(fixture.surface(fixture.handle)?.title != "autopilot-scratch")
        #expect(fixture.window?.title == "autopilot-scratch")
    }

    @Test func changeTabTitleStillWins() throws {
        guard let fixture = try makeFixture() else { return }
        defer { fixture.window?.close() }
        fixture.host.setAgentName(fixture.handle, name: "autopilot-scratch")

        fixture.controller.titleOverride = "Mine"
        #expect(fixture.window?.title == "Mine")

        fixture.controller.titleOverride = nil
        #expect(fixture.window?.title == "autopilot-scratch")
    }

    @Test func nonAttachSurfaceKeepsGhosttysTitle() async throws {
        guard let fixture = try makeFixture() else { return }
        defer { fixture.window?.close() }

        let surface = try #require(fixture.surface(fixture.handle))
        // The shell's own title (or Ghostty's 👻 fallback) races this one.
        surface.setTitle("plain shell")
        await waitForTerminalTitle(surface)

        #expect(!surface.title.isEmpty)
        #expect(fixture.window?.title == surface.title)
    }

    @Test func titleFollowsTheFocusedSplitsAgent() throws {
        guard let fixture = try makeFixture() else { return }
        defer { fixture.window?.close() }
        let (host, first) = (fixture.host, fixture.handle)
        let second = try host.openSplit(
            command: "", workingDirectory: nil, origin: fixture.origin,
            sourceSurface: first.surfaceID, direction: .right, requestID: UUID()
        )
        let plain = try host.openSplit(
            command: "", workingDirectory: nil, origin: fixture.origin,
            sourceSurface: second.surfaceID, direction: .down, requestID: UUID()
        )
        host.setAgentName(first, name: "alpha")
        host.setAgentName(second, name: "beta")

        fixture.focus(second)
        #expect(fixture.window?.title == "beta")
        fixture.focus(first)
        #expect(fixture.window?.title == "alpha")
        fixture.focus(plain)
        #expect(fixture.window?.title == fixture.surface(plain)?.title)
        #expect(fixture.window?.title != "alpha")
    }

    @Test func reattachInTheSameSlotKeepsTheName() throws {
        guard let fixture = try makeFixture() else { return }
        defer { fixture.window?.close() }
        fixture.host.setAgentName(fixture.handle, name: "autopilot-scratch")

        // The attach exited; the user reattaches from the placeholder left
        // in its place, which swaps in a fresh surface.
        let reattached = try fixture.host.fillPlaceholder(
            command: "", workingDirectory: nil, origin: fixture.origin,
            surfaceID: fixture.handle.surfaceID, requestID: UUID()
        )
        fixture.host.setAgentName(reattached, name: "autopilot-scratch")
        fixture.focus(reattached)

        #expect(fixture.window?.title == "autopilot-scratch")
    }

    @Test func exitedAttachKeepsItsNameUntilTheSlotIsRefilled() async throws {
        guard let fixture = try makeFixture() else { return }
        defer { fixture.window?.close() }
        fixture.host.setAgentName(fixture.handle, name: "autopilot-scratch")

        // The agent restarts: tmux (and the attach client) print their
        // last titles on the way out.
        fixture.surface(fixture.handle)?.setTitle("[exited]")
        await settleTitle()
        #expect(fixture.window?.title == "autopilot-scratch")

        // A plain shell chosen in the placeholder is not the agent.
        let shell = try fixture.host.fillPlaceholder(
            command: "", workingDirectory: nil, origin: fixture.origin,
            surfaceID: fixture.handle.surfaceID, requestID: UUID()
        )
        fixture.focus(shell)
        #expect(fixture.window?.title != "autopilot-scratch")
    }
}
