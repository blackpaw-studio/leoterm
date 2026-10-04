import Testing
@testable import Ghostty

/// The defaults reset (D-221) only works if it runs before the initial config
/// writes Sparkle's settings and before Sparkle starts and reads them.
struct UpdateLaunchSequenceTests {
    private enum Step: Equatable { case reset, config, start }

    @Test func resetsDefaultsBeforeConfigAndStart() {
        var steps: [Step] = []

        UpdateLaunchSequence.run(
            resetDefaults: { steps.append(.reset) },
            applyConfig: { steps.append(.config) },
            startUpdater: { steps.append(.start) })

        #expect(steps == [.reset, .config, .start])
    }
}
