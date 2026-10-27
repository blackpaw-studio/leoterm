import AppKit
import Testing

@testable import Ghostty

@MainActor
@Suite(.enabled(if: LeoWKTestHost.hasWindowServer, "needs a window-server session"))
struct LeoAgentBrowserParkingWindowTests {
    @Test func movesPastEveryScreenWhenTheScreensChange() {
        var screens = [NSRect(x: 0, y: 0, width: 1_000, height: 800)]
        let center = NotificationCenter()
        let window = LeoAgentBrowserParkingWindow(size: CGSize(width: 300, height: 200), screens: { screens }, notificationCenter: center)
        defer { window.close() }
        screens.append(NSRect(x: 1_000, y: -500, width: 6_000, height: 4_000))

        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        #expect(!screens.contains { $0.intersects(window.frame) })
        #expect(window.frame.size == CGSize(width: 300, height: 200))
    }
}
