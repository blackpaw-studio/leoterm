import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-059: the old tab shortcuts go to sidebar rows. Going to a row is a
/// single click on it.
@MainActor struct LeoRowCommandsTests {
    private let origin = LeoWindowID()

    private final class Log {
        var attaches: [LeoAgentRow.ID] = []
        var dispatchAttaches: [String] = []
        var shownTerminals: [UUID] = []
        var starts: [LeoAgentRow.ID] = []
    }

    private struct Fixture {
        let model: LeoSidebarModel
        let terminals: LeoWindowTerminals
        let log: Log
    }

    // MARK: Ghostty's goto_tab

    @Test func gotoTabMapsToRowMoves() {
        #expect(LeoRowCommands.move(for: ghostty_action_goto_tab_e(rawValue: 3)) == .number(3))
        #expect(LeoRowCommands.move(for: GHOSTTY_GOTO_TAB_LAST) == .last)
        #expect(LeoRowCommands.move(for: GHOSTTY_GOTO_TAB_NEXT) == .next)
        #expect(LeoRowCommands.move(for: GHOSTTY_GOTO_TAB_PREVIOUS) == .previous)
        #expect(LeoRowCommands.move(for: ghostty_action_goto_tab_e(rawValue: 0)) == nil)
    }

    // MARK: Going to a row

    @Test func selectRowClicksAgentRow() {
        let fixture = makeFixture(agents: ["a", "b", "c"])
        #expect(LeoRowCommands.perform(.number(2), model: fixture.model, terminals: fixture.terminals, from: origin))

        #expect(fixture.model.selection == id("b"))
        #expect(fixture.log.attaches == [id("b")], "an attach request to the content area, as a click makes")
    }

    @Test func selectRowActivatesTerminalRow() {
        let fixture = makeFixture(agents: ["a"], terminals: 2)
        let terminal = fixture.terminals.rows[1].id

        #expect(LeoRowCommands.perform(.last, model: fixture.model, terminals: fixture.terminals, from: origin))

        #expect(fixture.terminals.selection == terminal)
        #expect(fixture.log.shownTerminals == [terminal])
        #expect(fixture.log.attaches.isEmpty)
    }

    @Test func leavingATerminalRowForAnAgentClearsTheTerminalSelection() {
        let fixture = makeFixture(agents: ["a"], terminals: 1)
        fixture.terminals.activate(fixture.terminals.rows[0].id)

        #expect(LeoRowCommands.perform(.number(1), model: fixture.model, terminals: fixture.terminals, from: origin))

        #expect(fixture.terminals.selection == nil)
        #expect(LeoSidebarSelection.current(model: fixture.model, terminals: fixture.terminals) == .agent(id("a")))
    }

    @Test func selectRowAttachesDispatch() {
        let fixture = makeFixture(agents: ["a", "b"], dispatches: ["a": ["d1"]])

        #expect(LeoRowCommands.perform(.number(2), model: fixture.model, terminals: fixture.terminals, from: origin))

        #expect(fixture.log.dispatchAttaches == ["d1"])
        #expect(LeoSidebarSelection.current(model: fixture.model, terminals: fixture.terminals)
            == .dispatch(LeoDispatchRef(host: .local, id: "d1")))
    }

    @Test func aStoppedAgentGetsTheStartPromptAsAClickDoes() {
        let fixture = makeFixture(agents: ["a"], status: .stopped)

        #expect(LeoRowCommands.perform(.number(1), model: fixture.model, terminals: fixture.terminals, from: origin))

        #expect(fixture.model.startPrompt(in: origin)?.agent == id("a"))
        #expect(fixture.log.attaches.isEmpty)
    }

    @Test func nextAndPreviousWalkFromTheCurrentSelectionAcrossAgentsAndTerminals() {
        let fixture = makeFixture(agents: ["a", "b"], terminals: 1)
        func current() -> LeoSidebarItemID? { LeoSidebarSelection.current(model: fixture.model, terminals: fixture.terminals) }
        let terminal = LeoSidebarItemID.terminal(fixture.terminals.rows[0].id)

        LeoRowCommands.perform(.next, model: fixture.model, terminals: fixture.terminals, from: origin)
        #expect(current() == .agent(id("a")))
        LeoRowCommands.perform(.next, model: fixture.model, terminals: fixture.terminals, from: origin)
        LeoRowCommands.perform(.next, model: fixture.model, terminals: fixture.terminals, from: origin)
        #expect(current() == terminal)
        LeoRowCommands.perform(.next, model: fixture.model, terminals: fixture.terminals, from: origin)
        #expect(current() == .agent(id("a")), "wraps")
        LeoRowCommands.perform(.previous, model: fixture.model, terminals: fixture.terminals, from: origin)
        #expect(current() == terminal, "wraps back")
    }

    @Test func rowItemsDisabledWhenNoRows() {
        let empty = makeFixture(agents: [])
        #expect(!LeoRowCommands.canMove(model: empty.model, terminals: empty.terminals))
        #expect(!LeoRowCommands.perform(.next, model: empty.model, terminals: empty.terminals, from: origin))

        let one = makeFixture(agents: ["a"])
        #expect(LeoRowCommands.canMove(model: one.model, terminals: one.terminals))
    }

    // MARK: Editor tabs keep ⇧⌘] / ⇧⌘[ (D-460)

    @Test func nextTabGoesToEditorTabsWhenTwoOrMore_elseRows() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let tabs = LeoEditorTabs(makeAccess: { _ in LeoFileAccessor.local() })
            let fixture = makeFixture(agents: ["a", "b"])
            fixture.model.userSelected(id("a"))

            @MainActor func goNext() -> Bool {
                LeoRowCommands.gotoTab(
                    GHOSTTY_GOTO_TAB_NEXT, editorTabs: tabs, hasWindowTabs: false,
                    model: fixture.model, terminals: fixture.terminals, from: origin
                )
            }

            #expect(goNext(), "no editor tabs: the next row")
            #expect(fixture.model.selection == id("b"))

            for index in 0 ..< 2 {
                try await tabs.open(LeoEditorFileID(host: .local, path: try sandbox.file("f\(index).txt", "\(index)")))
            }
            #expect(goNext(), "two editor tabs: the next editor tab")
            #expect(tabs.document?.displayName == "f0.txt")
            #expect(fixture.model.selection == id("b"), "the rows stay put")
            await tabs.release()
        }
    }

    @Test func gotoTabLeavesWindowTabsToGhostty() {
        let fixture = makeFixture(agents: ["a", "b"])
        #expect(!LeoRowCommands.gotoTab(
            GHOSTTY_GOTO_TAB_NEXT, editorTabs: nil, hasWindowTabs: true,
            model: fixture.model, terminals: fixture.terminals, from: origin
        ))
        #expect(fixture.model.selection == nil)
    }

    // MARK: Helpers

    private func makeFixture(
        agents: [String], terminals count: Int = 0, status: LeoAgentStatus = .running, dispatches: [String: [String]] = [:]
    ) -> Fixture {
        let rows = agents.map { name in
            LeoAgentRow(host: .local, name: name, template: nil, status: status, activity: .idle, actionDetail: nil, startedAt: "s")
        }
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(
            rows: rows, connectivity: .connected, generation: 1,
            dispatchChildren: dispatches.mapValues { ids in
                ids.map {
                    LeoDispatchNode(dispatch: LeoDispatch(id: $0, name: "n-\($0)", status: "running", callerAgent: "a", attachable: true), depth: 0)
                }
            },
            features: LeoDaemonFeatures(["dispatch_tree", "dispatch_attach"])
        ))
        let log = Log()
        model.attachRequested = { row, _, _ in log.attaches.append(row.id) }
        model.dispatchAttachRequested = { identity, _, _ in log.dispatchAttaches.append(identity.dispatchID ?? "") }
        let terminals = LeoWindowTerminals()
        terminals.showRequested = { log.shownTerminals.append($0) }
        for index in 0 ..< count { terminals.add(UUID(), title: "t\(index)") }
        return Fixture(model: model, terminals: terminals, log: log)
    }

    private func id(_ name: String) -> LeoAgentRow.ID { LeoAgentRow.ID(host: .local, name: name) }
}
