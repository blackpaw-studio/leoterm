import Testing

@testable import LeoKit

struct LeoMachineStatusTests {
    @Test func onlyAConnectedMachineIsSelectable() {
        #expect(LeoMachineStatus.connected.isSelectable)
        #expect(!LeoMachineStatus.connecting.isSelectable)
        #expect(!LeoMachineStatus.failed("refused").isSelectable)
        #expect(!LeoMachineStatus.disabled.isSelectable)
    }
}
