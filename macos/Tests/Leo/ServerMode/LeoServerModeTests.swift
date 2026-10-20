import AppKit
import Foundation
import Testing

@testable import Ghostty

/// A10: server-only mode hides the app from the Dock and keeps it alive
/// without windows, and a config reload can't undo either.
struct LeoServerModeTests {
    typealias Hidden = Ghostty.Config.MacHidden

    @Test(arguments: [
        (Hidden.never, false, NSApplication.ActivationPolicy.regular),
        (Hidden.never, true, .accessory),
        (Hidden.always, false, .accessory),
        (Hidden.always, true, .accessory),
    ])
    func activationPolicyFollowsConfigUnlessServerOnly(
        hidden: Hidden, serverOnly: Bool, expected: NSApplication.ActivationPolicy
    ) {
        #expect(LeoServerMode.activationPolicy(macosHidden: hidden, serverOnly: serverOnly) == expected)
    }

    @Test(arguments: [
        (true, false, true),
        (true, true, false),
        (false, false, false),
        (false, true, false),
    ])
    func serverOnlyNeverQuitsAfterTheLastWindow(config: Bool, serverOnly: Bool, expected: Bool) {
        #expect(LeoServerMode.quitsAfterLastWindowClosed(config: config, serverOnly: serverOnly) == expected)
    }

    @Test(arguments: [
        (true, false, true),
        (true, true, false),
        (false, false, false),
        (false, true, false),
    ])
    func serverOnlyLaunchesWithoutAWindow(config: Bool, serverOnly: Bool, expected: Bool) {
        #expect(LeoServerMode.opensInitialWindow(config: config, serverOnly: serverOnly) == expected)
    }

    // MARK: - Controller

    @MainActor private final class Harness {
        let defaults = LeoInMemoryDefaults()
        var policies: [NSApplication.ActivationPolicy] = []
        var openedWindows = 0
        var activations = 0
        var windowCount = 0
        var hidden = Hidden.never

        func makeMode() -> LeoServerMode {
            LeoServerMode(
                defaults: defaults,
                macosHidden: { [unowned self] in hidden },
                windowCount: { [unowned self] in windowCount },
                applyPolicy: { [unowned self] in policies.append($0) },
                openWindow: { [unowned self] in openedWindows += 1 },
                activate: { [unowned self] in activations += 1 }
            )
        }
    }

    @MainActor @Test func startsOffAndPersistsTheChoiceUnderItsKey() {
        let harness = Harness()
        let mode = harness.makeMode()
        #expect(!mode.isServerOnly)

        mode.setServerOnly(true)

        #expect(harness.defaults.bool(forKey: "leo.serverOnly"))
        #expect(harness.makeMode().isServerOnly)
    }

    @MainActor @Test func enteringServerModeGoesAccessoryAndKeepsOpenWindows() {
        let harness = Harness()
        harness.windowCount = 2

        harness.makeMode().setServerOnly(true)

        #expect(harness.policies == [.accessory])
        #expect(harness.openedWindows == 0)
    }

    @MainActor @Test func leavingServerModeRestoresRegularAndOpensAWindowWhenNoneIsOpen() {
        let harness = Harness()
        let mode = harness.makeMode()
        mode.setServerOnly(true)

        mode.setServerOnly(false)

        #expect(harness.policies == [.accessory, .regular])
        #expect(harness.openedWindows == 1)
        #expect(harness.activations == 1)
        #expect(!harness.makeMode().isServerOnly)
    }

    @MainActor @Test func leavingServerModeKeepsExistingWindowsAndHonoursHiddenConfig() {
        let harness = Harness()
        harness.windowCount = 1
        harness.hidden = .always
        let mode = harness.makeMode()
        mode.setServerOnly(true)

        mode.setServerOnly(false)

        #expect(harness.policies == [.accessory, .accessory])
        #expect(harness.openedWindows == 0)
    }

    @MainActor @Test func settingTheCurrentValueDoesNothing() {
        let harness = Harness()
        let mode = harness.makeMode()

        mode.setServerOnly(false)

        #expect(harness.policies.isEmpty)
        #expect(harness.openedWindows == 0)
    }
}
