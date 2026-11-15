import AppKit
import Combine
import Testing

import LeoKit
@testable import Ghostty

/// Counts visibility reports the way `LeoPluginSurfaces` does: +1 for visible,
/// -1 for hidden. A balanced surface ends at 0 and never goes below it.
@MainActor final class CountingSlotSurface: LeoPluginSlotSurface {
    private(set) var counts: [LeoPluginSlotKey: Int] = [:]
    private(set) var lowest = 0
    var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    func content(for key: LeoPluginSlotKey) -> LeoPluginSlotContent { .loading }
    func retry(_ key: LeoPluginSlotKey) {}
    func perform(_ action: LeoPluginAction, gesture: LeoPluginGesture?, in key: LeoPluginSlotKey) {}
    func pop(_ key: LeoPluginSlotKey) {}
    func setVisible(_ key: LeoPluginSlotKey, _ visible: Bool) {
        counts[key, default: 0] += visible ? 1 : -1
        lowest = min(lowest, counts[key] ?? 0)
    }
    func count(_ key: LeoPluginSlotKey) -> Int { counts[key] ?? 0 }
}

@MainActor
struct LeoPluginVisibilityReporterTests {
    private let surface = CountingSlotSurface()
    private let key = LeoPluginSlotKey(pluginID: "studio.demo", slot: .section(id: "issues"))

    @Test
    func appearingAndDisappearingReportsOncePerChange() {
        let reporter = LeoPluginVisibilityReporter(key: key, surface: surface)

        reporter.setAppeared(true)
        reporter.setAppeared(true)
        #expect(surface.count(key) == 1)
        reporter.setAppeared(false)
        reporter.setAppeared(false)

        #expect(surface.count(key) == 0)
        #expect(surface.lowest == 0)
    }

    @Test
    func aThingIsVisibleOnlyWhileItIsActiveAsWellAsAppeared() {
        let reporter = LeoPluginVisibilityReporter(key: key, surface: surface, isActive: false)

        reporter.setAppeared(true)
        #expect(surface.count(key) == 0)
        reporter.setActive(true)
        #expect(surface.count(key) == 1)
        reporter.setActive(false)
        #expect(surface.count(key) == 0)
    }

    @Test
    func aReporterThatGoesAwayWhileVisibleReleasesItsCount() {
        var reporter: LeoPluginVisibilityReporter? = LeoPluginVisibilityReporter(key: key, surface: surface)
        reporter?.setAppeared(true)
        #expect(surface.count(key) == 1)

        reporter = nil

        #expect(surface.count(key) == 0)
    }

    @Test
    func aReporterThatNeverAppearedReleasesNothing() {
        var reporter: LeoPluginVisibilityReporter? = LeoPluginVisibilityReporter(key: key, surface: surface)
        reporter?.setAppeared(true)
        reporter?.setAppeared(false)

        reporter = nil

        #expect(surface.count(key) == 0)
        #expect(surface.lowest == 0)
    }

    // MARK: The slot host

    private func makeWindow() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        return (window, container)
    }

    @Test
    func closingTheWindowReleasesTheHostsCountAndNothingIsReleasedTwice() throws {
        let (window, container) = makeWindow()
        var host: LeoPluginSlotHostView? = LeoPluginSlotHostView(key: key, surface: surface)
        container.addSubview(try #require(host))
        #expect(surface.count(key) == 1)

        window.close()
        #expect(surface.count(key) == 0)

        host?.removeFromSuperview()
        host = nil
        #expect(surface.count(key) == 0)
        #expect(surface.lowest == 0)
    }

    @Test
    func aHostThatIsDeallocatedWhileVisibleReleasesItsCount() throws {
        let (window, container) = makeWindow()
        var host: LeoPluginSlotHostView? = LeoPluginSlotHostView(key: key, surface: surface)
        container.addSubview(try #require(host))
        #expect(surface.count(key) == 1)

        host?.removeFromSuperview()
        host = nil

        #expect(surface.count(key) == 0)
        #expect(surface.lowest == 0)
        window.close()
    }
}
