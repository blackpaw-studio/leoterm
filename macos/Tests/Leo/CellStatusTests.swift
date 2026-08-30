import Testing
@testable import Ghostty

struct CellStatusTests {
    @Test func agentWithBellNeedsYou() {
        #expect(deriveCellStatus(isAgent: true, hasBell: true, lifecycle: .running) == .needsYou)
    }

    @Test func agentRunningNoBellIsIdle() {
        #expect(deriveCellStatus(isAgent: true, hasBell: false, lifecycle: .running) == .idle)
    }

    @Test func stoppedAgentIsError() {
        #expect(deriveCellStatus(isAgent: true, hasBell: false, lifecycle: .stopped) == .error)
    }

    @Test func bellOnStoppedAgentStillError() {
        // Lifecycle error outranks a stale bell.
        #expect(deriveCellStatus(isAgent: true, hasBell: true, lifecycle: .stopped) == .error)
    }

    @Test func ptyCellNeverNeedsYou() {
        // Plain terminal cells use activity-only semantics (spec 5.1/5.3);
        // a bell does not promote a pty cell to needsYou.
        #expect(deriveCellStatus(isAgent: false, hasBell: true, lifecycle: nil) == .idle)
    }

    @Test func ptyCellIgnoresLifecycle() {
        // A pty cell is never an agent, so a stray lifecycle value is ignored.
        #expect(deriveCellStatus(isAgent: false, hasBell: false, lifecycle: .stopped) == .idle)
    }

    // MARK: - activity

    @Test func agentWorkingActivityIsWorking() {
        #expect(deriveCellStatus(isAgent: true, hasBell: false, lifecycle: .running, activity: .working) == .working)
    }

    @Test func agentIdleActivityIsIdle() {
        #expect(deriveCellStatus(isAgent: true, hasBell: false, lifecycle: .running, activity: .idle) == .idle)
    }

    @Test func agentUnknownActivityIsIdle() {
        #expect(deriveCellStatus(isAgent: true, hasBell: false, lifecycle: .running, activity: .unknown) == .idle)
    }

    @Test func bellOutranksWorkingActivity() {
        // needsYou (bell) takes priority over a live working signal.
        #expect(deriveCellStatus(isAgent: true, hasBell: true, lifecycle: .running, activity: .working) == .needsYou)
    }

    @Test func stoppedLifecycleOutranksWorkingActivity() {
        #expect(deriveCellStatus(isAgent: true, hasBell: false, lifecycle: .stopped, activity: .working) == .error)
    }

    @Test func ptyCellIgnoresWorkingActivity() {
        // Plain terminal cells never derive `.working` even if a stray
        // activity value is passed in.
        #expect(deriveCellStatus(isAgent: false, hasBell: false, lifecycle: nil, activity: .working) == .idle)
    }

    @Test func defaultActivityParameterIsUnknown() {
        // Existing call sites that omit `activity:` keep compiling and behave
        // as before (idle, absent a working signal).
        #expect(deriveCellStatus(isAgent: true, hasBell: false, lifecycle: .running) == .idle)
    }

    @Test func needsYouPulsesAndGlows() {
        #expect(CellStatus.needsYou.isPulsing)
        #expect(CellStatus.needsYou.hasGlow)
    }

    @Test func idleDoesNotPulseOrGlow() {
        #expect(!CellStatus.idle.isPulsing)
        #expect(!CellStatus.idle.hasGlow)
    }

    // MARK: - isVisible

    @Test func idleIsNotVisible() {
        // Idle uses absence as the visual signal — no dot rendered.
        #expect(!CellStatus.idle.isVisible)
    }

    @Test func needsYouIsVisible() {
        #expect(CellStatus.needsYou.isVisible)
    }

    @Test func errorIsVisible() {
        #expect(CellStatus.error.isVisible)
    }

    @Test func workingIsVisible() {
        #expect(CellStatus.working.isVisible)
    }

    // MARK: - accessibilityDescription

    @Test(arguments: [
        (CellStatus.working, "Working"),
        (CellStatus.idle, "Idle"),
        (CellStatus.needsYou, "Needs your attention"),
        (CellStatus.error, "Stopped with error"),
    ])
    func accessibilityDescriptionMatchesStatus(status: CellStatus, expected: String) {
        #expect(status.accessibilityDescription == expected)
    }

    // MARK: - statusWord

    @Test func needsYouStatusWordIsNeedsYou() {
        #expect(CellStatus.needsYou.statusWord == "needs you")
    }

    @Test func errorStatusWordIsStopped() {
        #expect(CellStatus.error.statusWord == "stopped")
    }

    @Test func idleAndWorkingHaveNoStatusWord() {
        #expect(CellStatus.idle.statusWord == nil)
        #expect(CellStatus.working.statusWord == nil)
    }
}
