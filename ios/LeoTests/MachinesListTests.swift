import ComposableArchitecture
import Foundation
import LeoFeatures
import LeoKit
import Testing
import UIKit

@testable import Leo

/// B-304, the Machines list on a busy machine. Serialized: each test hosts a
/// window and pumps the main run loop, and two at once slow each other down.
@MainActor
@Suite(.serialized)
struct MachinesListTests {
    /// Pushes and pops complete in place, so the test needs no transition time.
    private func withoutAnimations(_ body: () async throws -> Void) async rethrows {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        try await body()
    }

    /// A fleet change (an agent event on a busy machine) that leaves a row's own
    /// content alone used to rebuild its meters inside an animated snapshot apply:
    /// the gauges jumped.
    @Test func aFleetChangeThatLeavesTheRowAloneKeepsItsMeterViews() async throws {
        let rig = MachinesHost.rig()
        await MachinesHost.settle { !(MachinesHost.firstCell(rig).map { MachinesHost.meterViews(in: $0).isEmpty } ?? true) }
        let before = try #require(MachinesHost.firstCell(rig).map { MachinesHost.meterViews(in: $0) })
        try #require(!before.isEmpty)

        // An agent event: nothing the Machines row shows.
        rig.store.send(.fleet(.eventReceived(
            MachinesHost.daemon.id,
            .agentActivity(seq: 2, at: nil, agent: "zeus", activity: .working, currentAction: nil)
        )))
        await MachinesHost.drain()
        let after = try #require(MachinesHost.firstCell(rig).map { MachinesHost.meterViews(in: $0) })

        #expect(after.count == before.count)
        #expect(zip(before, after).allSatisfy { $0 === $1 })
    }

    /// After opening a machine and coming back, tapping its row did nothing (the
    /// row highlighted and that was all) until the app restarted.
    @Test func tappingARowOpensItsMachineEvenAfterBackingOutOfIt() async throws {
        try await withoutAnimations {
            let rig = MachinesHost.rig()
            await MachinesHost.settle { rig.store.fleet.sessions.first?.stats != nil }
            MachinesHost.tapFirstRow(rig)
            await MachinesHost.settle { rig.navigation.topViewController is MachineSettingsViewController }
            #expect(rig.navigation.topViewController is MachineSettingsViewController)

            rig.navigation.popViewController(animated: true)
            await MachinesHost.settle { rig.navigation.topViewController === rig.list }
            await MachinesHost.settle { rig.store.daemons.machine == nil }
            #expect(rig.store.daemons.machine == nil)
            await MachinesHost.drain()

            // Agent events keep arriving while the list is on screen.
            rig.store.send(.fleet(.eventReceived(
                MachinesHost.daemon.id,
                .agentActivity(seq: 2, at: nil, agent: "zeus", activity: .working, currentAction: nil)
            )))
            MachinesHost.tapFirstRow(rig)
            await MachinesHost.settle { rig.navigation.topViewController is MachineSettingsViewController }
            #expect(rig.navigation.topViewController is MachineSettingsViewController)
        }
    }
}
