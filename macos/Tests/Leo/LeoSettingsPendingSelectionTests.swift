import Testing

@testable import Ghostty
@testable import LeoKit

/// SwiftUI runs an alert's dismiss setter before the pressed button's action,
/// so the discard question's Discard button runs after the question is cleared.
@MainActor
struct LeoSettingsPendingSelectionTests {
    private final class Pane: LeoSettingsPane {
        var hasUnsavedChanges: Bool
        init(dirty: Bool) { hasUnsavedChanges = dirty }
        func discardChanges() { hasUnsavedChanges = false }
        func reload(using client: any LeoConfigClient) async {}
    }

    @Test func discardStillMovesTheSelectionWhenTheAlertDismissesFirst() throws {
        let harness = try LeoSettingsSidebarModelTests.harness()
        let pane = Pane(dirty: true)
        harness.target.register(pane, for: .config("templates"))
        let dionysus = LeoSettingsMachineRef.remote(LeoSettingsSidebarModelTests.dionysus.id)

        harness.sidebar.select(.pane(dionysus, .tasks))
        let pending = try #require(harness.sidebar.pendingSelection)
        harness.sidebar.cancelPending()
        harness.sidebar.confirm(pending)

        #expect(harness.sidebar.selection == .pane(dionysus, .tasks))
        #expect(harness.target.selectedHost == .remote("dionysus"))
        #expect(!pane.hasUnsavedChanges)
    }
}
