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
}
