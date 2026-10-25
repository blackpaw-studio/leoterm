import AppKit
import Testing

/// Tests that drive real key status (a palette panel taking key, `NSApp.sendEvent`
/// reaching the key window, a surface drawing focused) need the test host to be
/// the active app. A host started from a shell is not frontmost, and macOS
/// grants activation only while no other app holds the foreground, so on a
/// machine where something else runs windowed (a browser, a game capture) the
/// window never becomes key whatever the test does.
///
/// Such a test takes `.requiresActiveHost`, which skips it visibly when the host
/// can't be activated rather than failing on a precondition it doesn't own. A
/// CI run (`GITHUB_ACTIONS`) never skips: the runner has to be able to activate
/// the host, so a regression there fails the test.
@MainActor
enum LeoTestHostActivation {
    private static let timeout: Duration = .seconds(3)
    private static let retryInterval: Duration = .milliseconds(100)

    /// Asks again for the foreground; for the waits of a test that needs key
    /// status, where another app may take it back after the gate passed.
    static func requestForeground() {
        guard !NSApp.isActive else { return }
        NSApp.activate()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    static func isAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) async -> Bool {
        guard environment["GITHUB_ACTIONS"] == nil else { return true }
        let deadline = ContinuousClock.now + timeout
        while !NSApp.isActive, ContinuousClock.now < deadline {
            requestForeground()
            try? await Task.sleep(for: retryInterval)
        }
        return NSApp.isActive
    }
}

/// Whether a window can take key status on this host, decided by a plain
/// AppKit window rather than Leo's own. Every side effect is a seam so the
/// decision is testable without a real window server.
@MainActor
struct LeoFocusProbe {
    enum Outcome: Equatable {
        case available
        case unavailable(reason: String)
    }

    static let unavailableReason =
        "needs a key window: a plain probe window couldn't become key (screen locked or another app holds the foreground)"

    var environment: [String: String] = ProcessInfo.processInfo.environment
    var activate: () -> Void
    var orderProbeKey: () -> Void
    var isProbeKey: () -> Bool
    var closeProbe: () -> Void
    var pause: () async -> Void
    var attempts: Int

    func run() async -> Outcome {
        defer { closeProbe() }
        guard environment["GITHUB_ACTIONS"] == nil else { return .available }
        for attempt in 0..<attempts {
            activate()
            orderProbeKey()
            if isProbeKey() { return .available }
            if attempt < attempts - 1 { await pause() }
        }
        return .unavailable(reason: Self.unavailableReason)
    }

    static func live() -> LeoFocusProbe {
        let probe = ProbeWindow()
        return LeoFocusProbe(
            activate: { LeoTestHostActivation.requestForeground() },
            orderProbeKey: { probe.orderKey() },
            isProbeKey: { probe.isKey },
            closeProbe: { probe.close() },
            pause: { try? await Task.sleep(for: .milliseconds(100)) },
            attempts: 30)
    }

    /// The probe window, created on first use and closed once.
    private final class ProbeWindow {
        private var window: NSWindow?

        var isKey: Bool { window?.isKeyWindow ?? false }

        func orderKey() {
            let window = window ?? makeWindow()
            self.window = window
            window.makeKeyAndOrderFront(nil)
        }

        func close() {
            window?.close()
            window = nil
        }

        private func makeWindow() -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 80, y: 80, width: 120, height: 80),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
    }
}

extension Trait where Self == ConditionTrait {
    static var requiresActiveHost: Self {
        enabled("needs the test host to be the active app; another app holds the foreground") {
            await LeoTestHostActivation.isAvailable()
        }
    }
}
