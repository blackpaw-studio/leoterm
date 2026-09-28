import Foundation
import Testing

@testable import Ghostty

/// B-016: the sidebar selection vs. focus reports from the attach host,
/// driven end to end through a real coordinator and sidebar model.
@MainActor struct LeoAttachLinkPolishTests {
    private let local = LeoAgentIdentity(host: .local, name: "worker")
    private let other = LeoAgentIdentity(host: .local, name: "other")
    private let third = LeoAgentIdentity(host: .local, name: "third")
    private let origin = LeoWindowID()

    // MARK: (a) The user's click wins

    @Test func aFocusReportInFlightDuringAClickDoesNotSnapTheSelectionBack() async {
        let (host, coordinator, model) = makeLinked()
        await coordinator.attach(identity: local, from: origin, disposition: .reuseOrTab)
        await coordinator.attach(identity: other, from: origin, disposition: .newWindow)
        await host.emitAndWait(.focusChanged(host.handles[1]))
        #expect(model.selection == id(other))

        // Clicking `third` in the window showing `local`: activating that
        // window reports its focus, but the report is still in flight when
        // the click lands.
        host.emit(.focusChanged(host.handles[0]))
        model.rowClicked(row(third))
        await settle(host)

        #expect(model.selection == id(third))
        #expect(coordinator.linkState.focused == id(local), "the report itself still lands")

        await host.emitAndWait(.focusChanged(host.handles[1]))
        #expect(model.selection == id(other), "a report yielded after the click moves the selection again")
    }

    @Test func aFocusReportInFlightDuringAListSelectionDoesNotOverrideIt() async {
        let (host, coordinator, model) = makeLinked()
        await coordinator.attach(identity: local, from: origin, disposition: .reuseOrTab)

        host.emit(.focusChanged(host.handles[0]))
        model.userSelected(id(third))
        await settle(host)

        #expect(model.selection == id(third))
    }

    // MARK: (d) App reactivation

    @Test func reactivatingTheAppKeepsAnArrowKeySelection() async {
        let (host, coordinator, model) = makeLinked()
        await coordinator.attach(identity: local, from: origin, disposition: .reuseOrTab)
        await host.emitAndWait(.focusChanged(host.handles[0]))
        #expect(model.selection == id(local))
        model.userSelected(id(other))

        await host.emitAndWait(.focusSuspended)
        #expect(coordinator.focusedIdentity == nil, "the attention feed still hears the user isn't looking")
        await host.emitAndWait(.focusChanged(host.handles[0]))

        #expect(model.selection == id(other))
        #expect(coordinator.focusedIdentity == local)
    }

    @Test func focusResumingOnADifferentAttachAfterReactivationStillMovesTheSelection() async {
        let (host, coordinator, model) = makeLinked()
        await coordinator.attach(identity: local, from: origin, disposition: .reuseOrTab)
        await coordinator.attach(identity: other, from: origin, disposition: .newWindow)
        await host.emitAndWait(.focusChanged(host.handles[0]))

        await host.emitAndWait(.focusSuspended)
        await host.emitAndWait(.focusChanged(host.handles[1]))

        #expect(model.selection == id(other))
    }

    // MARK: Helpers

    /// Waits until every event yielded so far has been handled.
    private func settle(_ host: FakeAttachTabHost) async {
        // Closing a handle the coordinator never registered changes nothing.
        await host.emitAndWait(.closed(AttachmentHandle(surfaceID: UUID(), windowID: LeoWindowID())))
    }

    private func id(_ identity: LeoAgentIdentity) -> LeoAgentRow.ID { LeoAgentRow.ID(host: identity.host, name: identity.name) }

    private func row(_ identity: LeoAgentIdentity) -> LeoAgentRow {
        LeoAgentRow(host: identity.host, name: identity.name, template: nil, status: .running, activity: .idle, actionDetail: nil)
    }

    private func makeLinked() -> (FakeAttachTabHost, LeoAttachCoordinator, LeoSidebarModel) {
        let host = FakeAttachTabHost()
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(
            rows: [row(local), row(other), row(third)], connectivity: .connected, generation: 1
        ))
        let coordinator = LeoAttachCoordinator(
            host: host,
            executable: { "/leo" },
            report: { _ in },
            lifecycleEventHandled: { host.acknowledge($0) },
            linkStateChanged: { [weak model] in model?.receiveAttachLinks($0) }
        )
        model.latestFocusReport = { [weak coordinator] in coordinator?.latestFocusReport ?? 0 }
        return (host, coordinator, model)
    }
}
