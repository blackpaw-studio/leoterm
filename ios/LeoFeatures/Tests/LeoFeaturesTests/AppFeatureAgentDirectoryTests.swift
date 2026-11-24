import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct AppFeatureAgentDirectoryTests {
    @Test func aFleetChangeSavesTheAgentDirectoryForTheControlPicker() async {
        let written = LockIsolated<[[LeoAgentTarget]]>([])
        var state = AppFeatureChatTests.connected()
        state.fleet.sessions[0].agents = [Agent(.make("zeus")), Agent(.make("hera"))]
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.agentDirectory.write = { targets in written.withValue { $0.append(targets) } }
        }
        store.exhaustivity = .off

        await store.send(\.fleet.eventReceived, (PairedDaemon.dionysus.id, .agentStopped(seq: 2, at: nil, agent: "zeus", wakeOnMessage: false)))
        await store.finish()

        let machine = PairedDaemon.dionysus
        #expect(written.value == [[
            LeoAgentTarget(machineID: machine.id, machineName: machine.name, agent: "zeus"),
            LeoAgentTarget(machineID: machine.id, machineName: machine.name, agent: "hera"),
        ]])
    }
}
