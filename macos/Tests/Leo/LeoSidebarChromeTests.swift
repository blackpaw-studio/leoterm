import AppKit
import GhosttyKit
import SwiftUI
import Testing

@testable import Ghostty

struct LeoSidebarChromeTests {
    @Test func attachActivationMapsOptionModifierAndInvokesSinkOnce() {
        #expect(LeoAttachActivation.disposition(for: [.option]) == .newWindow)
        #expect(LeoAttachActivation.disposition(for: [.command, .shift]) == .reuseOrTab)

        let row = LeoAgentRow(host: .local, name: "agent", template: nil, status: .running, activity: .unknown, actionDetail: nil)
        var calls: [(LeoAgentRow, AttachDisposition)] = []
        LeoAttachActivation.activate(row: row, modifierFlags: [.option]) { row, disposition in
            calls.append((row, disposition))
        }

        #expect(calls.count == 1)
        #expect(calls.first?.0 == row)
        #expect(calls.first?.1 == .newWindow)
    }

    @Test func sidebarMenuStateReflectsVisibility() {
        #expect(LeoSidebarMenuState.state(isSidebarVisible: true) == .on)
        #expect(LeoSidebarMenuState.state(isSidebarVisible: false) == .off)
    }

    @Test func newAgentMenuRequiresLeoSession() {
        #expect(LeoSidebarMenuState.canCreateAgent(hasLeoSession: true))
        #expect(!LeoSidebarMenuState.canCreateAgent(hasLeoSession: false))
    }

    @Test func logsCommandQuotesExecutableAndAgentName() throws {
        #expect(try LeoLogsCommand.build(executablePath: "/leo", agentName: "-n") == "'/leo' agent logs -f -- '-n'")
        #expect(try LeoLogsCommand.build(executablePath: "/leo's", agentName: "a'b") == "'/leo'\\''s' agent logs -f -- 'a'\\''b'")
    }

    @Test(arguments: [
        (LeoAgentStatus.stopped, false, true, false, false),
        (LeoAgentStatus.running, false, false, true, true),
        (LeoAgentStatus.starting, false, false, false, false),
        (LeoAgentStatus.running, true, false, false, false)
    ]) func rowActionAvailability(status: LeoAgentStatus, pending: Bool, start: Bool, stop: Bool, restart: Bool) {
        let availability = LeoRowActionAvailability(status: status, isPending: pending)
        #expect(availability.start == start)
        #expect(availability.stop == stop)
        #expect(availability.restart == restart)
        #expect(availability.setTemplate == (!pending && (status == .stopped || status == .running)))
        #expect(availability.rename == (!pending && (status == .stopped || status == .running)))
        #expect(availability.delete == (!pending && (status == .stopped || status == .running)))
    }

    @Test func runningAgentDeleteErrorOffersStopFirst() {
        #expect(LeoDeleteActionState.canStopFirst(errorCode: "agent_still_running"))
        #expect(!LeoDeleteActionState.canStopFirst(errorCode: "other"))
    }

    @Test func shellQuoteHandlesHostileInputs() throws {
        #expect(try leoShellQuote("") == "''")
        #expect(try leoShellQuote("plain value") == "'plain value'")
        #expect(try leoShellQuote("a'b") == "'a'\\''b'")
        #expect(throws: LeoShellQuoteError.nulByte) {
            try leoShellQuote("before\0after")
        }
    }

    @Test func commandLauncherBuildsCommandOnlyConfiguration() throws {
        let command = try LeoCommandLauncher.startDaemonCommand(executablePath: "/tmp/leo's bin")
        let configuration = LeoCommandLauncher.configuration(command: command)

        #expect(command == "'/tmp/leo'\\''s bin' service start")
        #expect(configuration.command == command)
        #expect(configuration.environmentVariables.isEmpty)
    }

    @Test @MainActor func sessionOcclusionReducerTracksWindowState() {
        var state = LeoWindowVisibilityState()
        state.reduce(.occlusionChanged(isVisible: false))
        #expect(state.isOccluded)
        state.reduce(.miniaturized)
        #expect(state.isMiniaturized)
        state.reduce(.occlusionChanged(isVisible: true))
        state.reduce(.deminiaturized)
        #expect(!state.isOccluded)
        #expect(!state.isMiniaturized)
    }

    @Test func splitWidthClampsToPreferenceAndAvailableSpace() {
        #expect(LeoSidebarSplitMetrics.width(preferred: 100, available: 1_000) == 200)
        #expect(LeoSidebarSplitMetrics.width(preferred: 500, available: 1_000) == 420)
        #expect(LeoSidebarSplitMetrics.width(preferred: 300, available: 250) == 214)
        #expect(LeoSidebarSplitMetrics.width(preferred: 300, available: 230) == 200)
    }

    @Test @MainActor func splitDisplayedWidthDoesNotMutatePreference() {
        let defaults = UserDefaults(suiteName: "LeoSidebarSplitTests")!
        defaults.removePersistentDomain(forName: "LeoSidebarSplitTests")
        let session = LeoWindowSession(defaults: defaults)
        session.setPreferredWidth(500)

        #expect(LeoSidebarSplitMetrics.width(preferred: session.preferredWidth, available: 250) == 214)
        #expect(session.preferredWidth == 500)
    }
}
