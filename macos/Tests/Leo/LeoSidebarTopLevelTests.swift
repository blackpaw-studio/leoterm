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
}
