import AppKit
import GhosttyKit
import SwiftUI
import Testing

@testable import Ghostty

struct LeoSidebarChromeTests {
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
}
