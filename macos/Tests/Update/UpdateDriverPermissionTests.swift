import AppKit
import Testing
import Sparkle
@testable import Ghostty

/// Sparkle's "Check for updates automatically?" request is asked once, in
/// the update pill's popover (B-128). It never also opens Sparkle's standard
/// alert, even before the first terminal window is on screen.
@MainActor
struct UpdateDriverPermissionTests {
    /// Records what reaches Sparkle's reply block.
    private final class Recorder<Value>: @unchecked Sendable {
        private(set) var values: [Value] = []
        func record(_ value: Value) { values.append(value) }
    }

    /// Whether a terminal window can host the pill, flipped mid-test.
    private final class Flag: @unchecked Sendable {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    private static let windowCloseSettle: Duration = .milliseconds(100)

    private func driver(unobtrusive: @escaping () -> Bool) -> UpdateDriver {
        UpdateDriver(
            viewModel: UpdateViewModel(),
            hostBundle: .main,
            installsAllowed: false,
            hasUnobtrusiveTarget: unobtrusive)
    }

    private func visibleWindows() -> Set<ObjectIdentifier> {
        Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
    }

    private func request() -> SPUUpdatePermissionRequest {
        SPUUpdatePermissionRequest(systemProfile: [])
    }

    @Test(.timeLimit(.minutes(1)))
    func permissionRequestWithoutAWindowWaitsForThePill() async throws {
        let driver = driver { false }
        let sparkle = Recorder<SUUpdatePermissionResponse>()
        let before = visibleWindows()

        driver.show(request(), reply: sparkle.record)
        try await Task.sleep(for: .milliseconds(50))
        let opened = NSApp.windows.filter { $0.isVisible && !before.contains(ObjectIdentifier($0)) }
        opened.forEach { $0.close() }

        guard case .permissionRequest = driver.viewModel.state else {
            Issue.record("expected the permission-request state, got \(driver.viewModel.state)")
            return
        }
        #expect(opened.isEmpty, "no standard alert may open: \(opened.map(\.title))")
    }

    @Test func answeringThePillRepliesToSparkleOnce() {
        let driver = driver { false }
        let sparkle = Recorder<SUUpdatePermissionResponse>()

        driver.show(request(), reply: sparkle.record)
        guard case let .permissionRequest(pending) = driver.viewModel.state else {
            Issue.record("expected the permission-request state, got \(driver.viewModel.state)")
            return
        }
        pending.reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: true, automaticUpdateDownloading: nil, sendSystemProfile: false))

        #expect(sparkle.values.count == 1)
        guard case .idle = driver.viewModel.state else {
            Issue.record("expected idle after answering, got \(driver.viewModel.state)")
            return
        }
    }

    @Test func closingTheLastWindowKeepsThePermissionRequest() async throws {
        let hasWindow = Flag(true)
        let driver = driver { hasWindow.value }
        let sparkle = Recorder<SUUpdatePermissionResponse>()

        driver.show(request(), reply: sparkle.record)
        hasWindow.value = false
        NotificationCenter.default.post(name: TerminalWindow.terminalWillCloseNotification, object: nil)
        try await Task.sleep(for: Self.windowCloseSettle)

        guard case .permissionRequest = driver.viewModel.state else {
            Issue.record("the pending request was dropped: \(driver.viewModel.state)")
            return
        }
        #expect(sparkle.values.isEmpty)
    }
}
