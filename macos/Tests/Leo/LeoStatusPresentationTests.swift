import Testing

@testable import Ghostty

struct LeoStatusPresentationTests {
    @Test func activityMapsEveryCaseToADistinctSymbolAndLabel() {
        let working = LeoStatusPresentation.activity(.working)
        #expect(working.symbolName == "circle.fill")
        #expect(working.accessibilityLabel == "Working")

        let idle = LeoStatusPresentation.activity(.idle)
        #expect(idle.symbolName == "circle")
        #expect(idle.accessibilityLabel == "Idle")

        let unknown = LeoStatusPresentation.activity(.unknown)
        #expect(unknown.accessibilityLabel == "Activity unknown")

        // Working and idle must differ in shape, not merely color.
        #expect(working.symbolName != idle.symbolName)
    }

    @Test func agentStatusMapsEveryCaseIncludingUnknown() {
        #expect(LeoStatusPresentation.agentStatus(.running).accessibilityLabel == "Running")
        #expect(LeoStatusPresentation.agentStatus(.starting).accessibilityLabel == "Starting")
        #expect(LeoStatusPresentation.agentStatus(.stopped).accessibilityLabel == "Stopped")

        let unknown = LeoStatusPresentation.agentStatus(.unknown("weird"))
        #expect(unknown.accessibilityLabel == "Status: weird")
        #expect(unknown.symbolName == "questionmark.circle")
    }

    @Test func hostConnectionIsNeutralWhenNotSelectedRegardlessOfState() {
        let neutral = LeoStatusPresentation.hostConnection(isSelected: false, state: .connected(socketPath: "/tmp/s"))
        #expect(neutral.accessibilityLabel == "Not connected")
        #expect(neutral.symbolName == "circle")

        let neutralNoState = LeoStatusPresentation.hostConnection(isSelected: false, state: nil)
        #expect(neutralNoState.accessibilityLabel == "Not connected")
    }

    @Test func hostConnectionMapsEverySelectedStateToADistinctSymbol() {
        let connected = LeoStatusPresentation.hostConnection(isSelected: true, state: .connected(socketPath: "/tmp/s"))
        #expect(connected.symbolName == "circle.fill")
        #expect(connected.accessibilityLabel == "Connected")

        let connecting = LeoStatusPresentation.hostConnection(isSelected: true, state: .connecting)
        #expect(connecting.symbolName == "circle.dotted")
        #expect(connecting.accessibilityLabel == "Connecting")

        let failed = LeoStatusPresentation.hostConnection(isSelected: true, state: .failed(message: "boom", hint: nil))
        #expect(failed.symbolName == "exclamationmark.triangle.fill")
        #expect(failed.accessibilityLabel == "Connection failed")
    }

    @Test func hostConnectionSelectedWithNilStateFallsBackToNeutral() {
        let presentation = LeoStatusPresentation.hostConnection(isSelected: true, state: nil)
        #expect(presentation.accessibilityLabel == "Not connected")
    }
}
