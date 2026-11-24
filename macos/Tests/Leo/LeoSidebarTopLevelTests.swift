import Testing

@testable import Ghostty
@testable import LeoKit

struct LeoSidebarTopLevelTests {
    @Test func pluginSectionAppearsOnceAtTheTopLevelAfterMachinesAndTerminals() {
        let blocks = LeoSidebarTopLevel.blocks(
            machines: [.local, .remote("studio")], showsTerminals: true, pluginSectionIDs: ["p/issues"]
        )

        #expect(blocks == [.machine(.local), .machine(.remote("studio")), .terminals, .pluginSection(id: "p/issues")])
        #expect(blocks.filter { $0 == .pluginSection(id: "p/issues") }.count == 1)
    }

    @Test func pluginSectionsFollowMachinesWhenThereAreNoTerminals() {
        let blocks = LeoSidebarTopLevel.blocks(machines: [.local], showsTerminals: false, pluginSectionIDs: ["a", "b"])
        #expect(blocks == [.machine(.local), .pluginSection(id: "a"), .pluginSection(id: "b")])
    }

    // MARK: B-438 order

    @Test func savedOrderPlacesAPluginSectionAboveAgents() {
        let blocks = LeoSidebarTopLevel.blocks(
            machines: [.local, .remote("studio")], showsTerminals: true, pluginSectionIDs: ["x"],
            order: [LeoSidebarSectionOrder.pluginKey("x"), LeoSidebarSectionOrder.agents, LeoSidebarSectionOrder.terminals]
        )
        #expect(blocks == [.pluginSection(id: "x"), .machine(.local), .machine(.remote("studio")), .terminals])
    }

    @Test func movingAMachineMovesTheWholeAgentsUnit() {
        let machines: [LeoHostID] = [.local, .remote("studio")]
        let before = LeoSidebarTopLevel.blocks(machines: machines, showsTerminals: true, pluginSectionIDs: [], order: [])
        let visible = LeoSidebarTopLevel.sectionKeys(of: before)
        #expect(visible == [LeoSidebarSectionOrder.agents, LeoSidebarSectionOrder.terminals], "the machines are one section")

        let order = LeoSidebarSectionOrder.moving(
            LeoSidebarTopLevel.Block.machine(.remote("studio")).orderKey, .down, visible: visible, saved: [], known: visible
        )
        let after = LeoSidebarTopLevel.blocks(machines: machines, showsTerminals: true, pluginSectionIDs: [], order: order ?? [])
        #expect(after == [.terminals, .machine(.local), .machine(.remote("studio"))])
    }

    @Test func aSectionStartsBelowTheRowsOfTheSectionsAboveIt() {
        let sections = [LeoSidebarSectionOrder.pluginKey("x"), LeoSidebarSectionOrder.agents, LeoSidebarSectionOrder.terminals]
        let rows = [sections[0]: 2, sections[1]: 7, sections[2]: 3]
        #expect(LeoSidebarTopLevel.rowOffset(of: sections[0], in: sections, rowCounts: rows) == 0)
        #expect(LeoSidebarTopLevel.rowOffset(of: sections[1], in: sections, rowCounts: rows) == 2)
        #expect(LeoSidebarTopLevel.rowOffset(of: sections[2], in: sections, rowCounts: rows) == 9)
    }
}
