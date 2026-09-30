import AppKit
import Testing

@testable import Ghostty

/// B-085: a window frame too small to use is never saved and never
/// restored, so a window that once shrank (B-086) doesn't come back tiny
/// on every later launch. Everything else restores as before.
struct LastWindowPositionTests {
    /// A screen's visible frame below a menu bar and above a Dock.
    private let visibleFrame = NSRect(x: 0, y: 70, width: 1440, height: 830)
    /// The window's frame before restoring: the nib's default size.
    private let current = NSRect(x: 100, y: 100, width: 800, height: 632)
    private let minimum = LastWindowPosition.minimumSize(windowMinSize: .zero)

    private func restored(_ saved: [Double], origin: Bool = true, size: Bool = true) -> NSRect? {
        LastWindowPosition.restoredFrame(
            saved: saved,
            current: current,
            visibleFrame: visibleFrame,
            minimumSize: minimum,
            restoreOrigin: origin,
            restoreSize: size
        )
    }

    // MARK: Restore

    @Test func tinySavedSizeIsNotRestored() throws {
        let frame = try #require(restored([300, 400, 40, 30]))

        #expect(frame.width >= minimum.width && frame.height >= minimum.height)
        #expect(frame.size == current.size)
        // The saved origin still applies, pulled up so the window fits.
        #expect(frame.origin == NSPoint(x: 300, y: visibleFrame.maxY - current.height))
    }

    @Test(arguments: [[300, 400, 1200, 100], [300, 400, 120, 700]] as [[Double]])
    func savedSizeUnderTheMinimumInEitherDimensionIsNotRestored(saved: [Double]) throws {
        let frame = try #require(restored(saved))

        #expect(frame.size == current.size)
    }

    @Test func tinySavedSizeWithAConfiguredOriginRestoresNothing() {
        #expect(restored([300, 400, 40, 30], origin: false) == nil)
    }

    @Test func usableSavedFrameIsRestored() {
        #expect(restored([200, 150, 1000, 700]) == NSRect(x: 200, y: 150, width: 1000, height: 700))
    }

    @Test func oversizedSavedFrameIsClampedToVisibleFrame() {
        #expect(restored([0, 70, 3000, 2000]) == visibleFrame)
    }

    @Test func offscreenOriginIsPulledOnScreen() {
        #expect(restored([-500, 5000, 800, 600]) == NSRect(x: 0, y: 300, width: 800, height: 600))
    }

    @Test func configuredSizeKeepsTheCurrentSize() {
        #expect(restored([200, 150, 40, 30], size: false) == NSRect(x: 200, y: 150, width: 800, height: 632))
    }

    @Test func configuredOriginRestoresOnlyTheSize() {
        #expect(restored([200, 150, 1000, 700], origin: false) == NSRect(x: 100, y: 100, width: 1000, height: 700))
    }

    @Test func nothingIsRestoredWithoutASavedOrigin() {
        #expect(restored([]) == nil)
        #expect(restored([5]) == nil)
        #expect(restored([200, 150, 1000, 700], origin: false, size: false) == nil)
    }

    @Test func minimumSizeIsTheLargerOfTheWindowsAndLeosFloor() {
        let floor = LastWindowPosition.minimumSize(windowMinSize: .zero)

        #expect(floor.width >= LeoSidebarSplitMetrics.minimumWidth + LeoSidebarSplitMetrics.terminalFloor)
        #expect(floor.height >= 200)
        #expect(LastWindowPosition.minimumSize(windowMinSize: NSSize(width: 2000, height: 50))
            == NSSize(width: 2000, height: floor.height))
    }

    // MARK: Save

    @Test func tinyFrameIsNotSaved() {
        let defaults = LeoInMemoryDefaults()
        let position = LastWindowPosition(defaults: defaults)

        #expect(!position.save(frame: NSRect(x: 300, y: 400, width: 40, height: 30), minimumSize: minimum))
        #expect(defaults.object(forKey: LastWindowPosition.positionKey) == nil)
    }

    @Test func tinyFrameKeepsTheLastUsableFrame() {
        let defaults = LeoInMemoryDefaults()
        let position = LastWindowPosition(defaults: defaults)

        #expect(position.save(frame: NSRect(x: 200, y: 150, width: 1000, height: 700), minimumSize: minimum))
        #expect(!position.save(frame: NSRect(x: 300, y: 400, width: 266, height: 221), minimumSize: minimum))

        #expect(defaults.array(forKey: LastWindowPosition.positionKey) as? [Double] == [200, 150, 1000, 700])
    }
}
