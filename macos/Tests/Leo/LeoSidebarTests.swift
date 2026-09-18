import Foundation
import Testing

@testable import Ghostty

struct LeoSidebarTests {
    @Test func reducersRankFilterMergeAndRejectStaleResults() {
        let stopped = row("z", status: .stopped)
        let working = row("b", status: .running, activity: .working)
        let running = row("a", template: "swift", status: .running)
        let starting = row("c", status: .starting)
        #expect(LeoSidebarReducers.rank([stopped, running, starting, working]).map(\.name) == ["b", "a", "c", "z"])
        #expect(LeoSidebarReducers.filter([running], query: "swift") == [running])
        #expect(LeoSidebarReducers.mergeActivity([stopped], activityByName: ["z": .init(activity: .working, detail: "x")]).first?.activity == .unknown)
        let snapshot = LeoSidebarSnapshot(rows: [running], connectivity: .connected, generation: 2)
        #expect(LeoSidebarReducers.applyListResult(snapshot, result: [stopped], generation: 1) == snapshot)
    }

    @Test func schedulerPausesAndCoalesces() {
        var scheduler = LeoPollScheduler(now: { Date(timeIntervalSince1970: 0) })
        #expect(scheduler.reduce(.sidebarVisibleCountChanged(1)) == [.resume, .refreshNow, .scheduleTick(after: 2)])
        #expect(scheduler.reduce(.refreshStarted).isEmpty)
        #expect(scheduler.reduce(.tick) == [.scheduleTick(after: 2)])
        #expect(scheduler.reduce(.refreshFinished) == [.refreshNow])
        #expect(scheduler.reduce(.windowOcclusionChanged(true)) == [.pause])
    }

    @Test func schedulerBoundsFollowUpRefreshAfterManyTicks() {
        var scheduler = LeoPollScheduler(now: { Date(timeIntervalSince1970: 0) })
        _ = scheduler.reduce(.sidebarVisibleCountChanged(1))
        _ = scheduler.reduce(.refreshStarted)

        for _ in 0..<10 {
            #expect(scheduler.reduce(.tick) == [.scheduleTick(after: 2)])
        }

        #expect(scheduler.reduce(.refreshFinished) == [.refreshNow])
    }

    @Test @MainActor func modelPreservesSelectionAndFilters() {
        let first = row("a", template: "swift")
        let model = LeoSidebarModel(snapshot: .init(rows: [first], connectivity: .connected, generation: 0))
        model.selection = first.id
        model.query = "swift"
        model.receive(.init(rows: [first], connectivity: .connected, generation: 1))
        #expect(model.selection == first.id)
        #expect(model.visibleRows == [first])
    }

    @Test @MainActor func modelRejectsOutOfOrderSnapshots() {
        let model = LeoSidebarModel()
        let newer = row("newer")
        let older = row("older")

        model.receive(.init(rows: [newer], connectivity: .connected, generation: 2))
        model.receive(.init(rows: [older], connectivity: .connected, generation: 1))

        #expect(model.snapshot.generation == 2)
        #expect(model.snapshot.rows == [newer])
    }

    @Test @MainActor func windowSessionDefaultsToHiddenSidebarOnFreshInstall() {
        let suiteName = "LeoSidebarTests.fresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let session = LeoWindowSession(defaults: defaults)
        #expect(!session.isSidebarVisible)
    }

    /// A hidden sidebar (the default) must not make the window unpollable
    /// while the agent palette is open -- otherwise the palette shows a
    /// stale/empty agent list. `setPickerPresented(_:)` is the only other
    /// input to `isPollable` besides `isSidebarVisible`.
    @Test @MainActor func windowSessionIsPollableWhilePickerPresentedEvenWithSidebarHidden() {
        let suiteName = "LeoSidebarTests.pickerPresented.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let session = LeoWindowSession(defaults: defaults)

        #expect(!session.isSidebarVisible)
        #expect(!session.isPollable)

        session.setPickerPresented(true)
        #expect(session.isPollable)

        session.setPickerPresented(false)
        #expect(!session.isPollable)
    }

    @Test @MainActor func windowSessionReadsWritesAndClampsDefaults() {
        let defaults = UserDefaults(suiteName: "LeoSidebarTests")!
        defaults.removePersistentDomain(forName: "LeoSidebarTests")
        defaults.set(false, forKey: "leo.sidebarVisible")
        defaults.set(500, forKey: "leo.sidebarWidth")
        let session = LeoWindowSession(defaults: defaults)
        #expect(!session.isSidebarVisible)
        #expect(session.preferredWidth == 500)
        #expect(session.displayedWidth == 420)
        session.setPreferredWidth(100)
        #expect(session.preferredWidth == 100)
        #expect(session.displayedWidth == 200)
        #expect(defaults.double(forKey: "leo.sidebarWidth") == 100)
    }

    private func row(_ name: String, template: String? = nil, status: LeoAgentStatus = .running, activity: LeoAgentRow.Activity = .unknown) -> LeoAgentRow {
        .init(host: .local, name: name, template: template, status: status, activity: activity, actionDetail: nil)
    }
}
