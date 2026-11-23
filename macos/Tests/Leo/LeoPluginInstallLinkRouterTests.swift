import Foundation
import OSLog
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor struct LeoPluginInstallLinkRouterTests {
    final class Recorder {
        var opened = 0
        var errors: [String] = []
        var onError: () -> Void = {}
        /// False when Settings stayed put (the unsaved-changes prompt was cancelled).
        var navigates = true
    }

    static let bad = URL(string: "leo://plugin/install?url=http%3A%2F%2Fx")!
    static let good = URL(string: "leo://plugin/install?url=https%3A%2F%2Fgithub.com%2Facme%2Fdemo&ref=v1")!

    static func router(_ recorder: Recorder) -> LeoPluginInstallLinkRouter {
        LeoPluginInstallLinkRouter(
            openPluginsSettings: { recorder.opened += 1; return recorder.navigates }, showError: { recorder.errors.append($0); recorder.onError() },
            logger: Logger(subsystem: "studio.blackpaw.leo.macos.tests", category: "links"))
    }

    @Test func badLinkShowsErrorAndDoesNotOpen() {
        let recorder = Recorder()
        let router = Self.router(recorder)
        router.markReady()

        router.receive(URL(string: "leo://plugin/install?url=http%3A%2F%2Fx")!)

        #expect(recorder.errors.count == 1)
        #expect(recorder.opened == 0)
        #expect(router.pending == nil)
    }

    @Test func malformedLinkWhileInstallUIOpenShowsNoAlert() {
        let recorder = Recorder()
        let router = Self.router(recorder)
        router.markReady()
        router.isInstallUIOpen = true

        router.receive(Self.bad)

        #expect(recorder.errors.isEmpty)
    }

    @Test func malformedLinkWhileAnotherIsPendingShowsNoAlert() {
        let recorder = Recorder()
        let router = Self.router(recorder)
        router.receive(Self.good)

        router.receive(Self.bad)

        #expect(recorder.errors.isEmpty)
        #expect(router.pending != nil)
    }

    @Test func noSecondErrorAlertWhileOneIsUp() {
        let recorder = Recorder()
        let router = Self.router(recorder)
        router.markReady()
        recorder.onError = { router.receive(Self.bad) }   // a page firing again while the modal alert is open

        router.receive(Self.bad)

        #expect(recorder.errors.count == 1)
    }

    @Test func anErrorAlertCanShowAgainAfterTheFirstIsDismissed() {
        let recorder = Recorder()
        let router = Self.router(recorder)

        router.receive(Self.bad)
        router.receive(Self.bad)

        #expect(recorder.errors.count == 2)
    }

    @Test func linkWhileInstallUIOpenIsIgnored() {
        let recorder = Recorder()
        let router = Self.router(recorder)
        router.markReady()
        router.isInstallUIOpen = true

        router.receive(Self.good)

        #expect(router.pending == nil)
        #expect(recorder.opened == 0)
        #expect(recorder.errors.isEmpty)
    }

    @Test func linkBeforeReadyIsHeldUntilMarkReady() {
        let recorder = Recorder()
        let router = Self.router(recorder)

        router.receive(Self.good)
        #expect(recorder.opened == 0)
        #expect(router.pending?.ref == "v1")

        router.markReady()
        router.markReady()

        #expect(recorder.opened == 1)
    }

    @Test func aReadyRouterOpensSettingsAndHandsTheLinkOverOnce() {
        let recorder = Recorder()
        let router = Self.router(recorder)
        router.markReady()

        router.receive(Self.good)

        #expect(recorder.opened == 1)
        #expect(router.take()?.url.absoluteString == "https://github.com/acme/demo")
        #expect(router.take() == nil)
    }

    @Test func linkIsDroppedWhenSettingsDidNotNavigate() {
        let recorder = Recorder()
        let router = Self.router(recorder)
        router.markReady()
        recorder.navigates = false

        router.receive(Self.good)
        #expect(router.pending == nil)

        recorder.navigates = true
        router.receive(Self.good)
        #expect(router.pending != nil)
    }

    @Test func aHeldLinkIsDroppedWhenTheFirstNavigationAtLaunchFails() {
        let recorder = Recorder()
        let router = Self.router(recorder)
        recorder.navigates = false
        router.receive(Self.good)

        router.markReady()

        #expect(router.pending == nil)
    }

    @Test func aSecondLinkWhileOneIsPendingIsDropped() {
        let recorder = Recorder()
        let router = Self.router(recorder)

        router.receive(Self.good)
        router.receive(URL(string: "leo://plugin/install?url=https%3A%2F%2Fgithub.com%2Fother%2Fx")!)

        #expect(router.take()?.url.absoluteString == "https://github.com/acme/demo")
    }
}
