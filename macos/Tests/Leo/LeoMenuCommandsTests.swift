import AppKit
import Testing

@testable import Ghostty

struct LeoMenuCommandsTests {
    @Test @MainActor func setTemplateItemIsFoundByIdentifierNotTitle() {
        let item = NSMenuItem(title: "Set Template", action: nil, keyEquivalent: "")
        item.identifier = LeoAgentsMenuController.setTemplateItemIdentifier
        let menu = NSMenu()
        menu.addItem(item)

        // Renaming/localizing the title must not break the lookup.
        item.title = "Définir le modèle"

        let found = menu.items.first(where: { $0.identifier == LeoAgentsMenuController.setTemplateItemIdentifier })
        #expect(found === item)
    }

    @Test func sidebarToggleTitleFlipsWithVisibility() {
        #expect(LeoMenuCommands.sidebarToggleTitle(hasLeoSession: true, isSidebarVisible: true) == "Hide Agents Sidebar")
        #expect(LeoMenuCommands.sidebarToggleTitle(hasLeoSession: true, isSidebarVisible: false) == "Show Agents Sidebar")
    }

    @Test func sidebarToggleTitleFallsBackAndDisablesWithoutSession() {
        #expect(LeoMenuCommands.sidebarToggleTitle(hasLeoSession: false, isSidebarVisible: true) == "Show Agents Sidebar")
        #expect(!LeoMenuCommands.canToggleSidebar(hasLeoSession: false))
        #expect(LeoMenuCommands.canToggleSidebar(hasLeoSession: true))
    }

    /// D-059: Show Agents Sidebar is disabled (so ⌘⇧L beeps) while
    /// showing it would take the terminal under its floor; Hide never is.
    @Test func showingTheSidebarIsDisabledWhereItWouldSqueezeTheTerminal() {
        #expect(!LeoMenuCommands.canToggleSidebar(hasLeoSession: true, isSidebarVisible: false, showingSqueezesTerminal: true))
        #expect(LeoMenuCommands.canToggleSidebar(hasLeoSession: true, isSidebarVisible: false, showingSqueezesTerminal: false))
        #expect(LeoMenuCommands.canToggleSidebar(hasLeoSession: true, isSidebarVisible: true, showingSqueezesTerminal: true))
        #expect(!LeoMenuCommands.canToggleSidebar(hasLeoSession: false, isSidebarVisible: true, showingSqueezesTerminal: false))
    }

    @Test func createAgentRequiresLeoSession() {
        #expect(LeoMenuCommands.canCreateAgent(hasLeoSession: true))
        #expect(!LeoMenuCommands.canCreateAgent(hasLeoSession: false))
    }

    @Test func agentCommandsDisabledWithoutLeoSession() {
        let availability = LeoRowActionAvailability(status: .running, isPending: false)
        let context = LeoMenuCommands.AgentContext(hasLeoSession: false, availability: availability)
        #expect(!LeoMenuCommands.canAttach(context))
        #expect(!LeoMenuCommands.canStart(context))
        #expect(!LeoMenuCommands.canStop(context))
        #expect(!LeoMenuCommands.canRestart(context))
        #expect(!LeoMenuCommands.canSetTemplate(context))
        #expect(!LeoMenuCommands.canRename(context))
        #expect(!LeoMenuCommands.canViewLogs(context))
        #expect(!LeoMenuCommands.canDelete(context))
    }

    @Test func agentCommandsDisabledWithoutSelection() {
        let context = LeoMenuCommands.AgentContext(hasLeoSession: true, availability: nil)
        #expect(!LeoMenuCommands.canAttach(context))
        #expect(!LeoMenuCommands.canStart(context))
        #expect(!LeoMenuCommands.canStop(context))
        #expect(!LeoMenuCommands.canRestart(context))
        #expect(!LeoMenuCommands.canSetTemplate(context))
        #expect(!LeoMenuCommands.canRename(context))
        #expect(!LeoMenuCommands.canViewLogs(context))
        #expect(!LeoMenuCommands.canDelete(context))
    }

    struct AgentAvailabilityCase: Sendable {
        let status: LeoAgentStatus
        let pending: Bool
        let start: Bool
        let stop: Bool
        let restart: Bool
        let setTemplate: Bool
        let rename: Bool
        let delete: Bool
        let attach: Bool
        let logs: Bool
    }

    @Test(arguments: [
        AgentAvailabilityCase(
            status: .stopped, pending: false, start: true, stop: false, restart: false,
            setTemplate: true, rename: true, delete: true, attach: true, logs: true
        ),
        AgentAvailabilityCase(
            status: .running, pending: false, start: false, stop: true, restart: true,
            setTemplate: true, rename: true, delete: true, attach: true, logs: true
        ),
        AgentAvailabilityCase(
            status: .starting, pending: false, start: false, stop: false, restart: false,
            setTemplate: false, rename: false, delete: false, attach: true, logs: true
        ),
        AgentAvailabilityCase(
            status: .running, pending: true, start: false, stop: false, restart: false,
            setTemplate: false, rename: false, delete: false, attach: false, logs: false
        )
    ]) func agentCommandsFollowRowAvailability(scenario testCase: AgentAvailabilityCase) {
        let context = LeoMenuCommands.AgentContext(
            hasLeoSession: true,
            availability: LeoRowActionAvailability(status: testCase.status, isPending: testCase.pending)
        )
        #expect(LeoMenuCommands.canStart(context) == testCase.start)
        #expect(LeoMenuCommands.canStop(context) == testCase.stop)
        #expect(LeoMenuCommands.canRestart(context) == testCase.restart)
        #expect(LeoMenuCommands.canSetTemplate(context) == testCase.setTemplate)
        #expect(LeoMenuCommands.canRename(context) == testCase.rename)
        #expect(LeoMenuCommands.canDelete(context) == testCase.delete)
        #expect(LeoMenuCommands.canAttach(context) == testCase.attach)
        #expect(LeoMenuCommands.canViewLogs(context) == testCase.logs)
    }

    /// B-262: the control verbs each have one Agents menu item on a ⌃⌘
    /// combination nothing else in the xib uses.
    @Test func controlShortcutsAreBoundOnceAndUnique() throws {
        let xib = try LeoMenuXib.shortcuts()
        let expected = [
            ("messageSelectedLeoAgent:", "⌃⌘m"), ("interruptSelectedLeoAgent:", "⌃⌘."),
            ("compactSelectedLeoAgent:", "⌃⌘k"), ("clearSelectedLeoAgent:", "⌃⇧⌘k"),
        ]
        for (action, shortcut) in expected {
            #expect(xib.filter { $0.shortcut == shortcut }.map(\.action) == [action], "\(shortcut) belongs to \(action) alone")
            #expect(xib.filter { $0.action == action }.count == 1)
        }
    }
}
