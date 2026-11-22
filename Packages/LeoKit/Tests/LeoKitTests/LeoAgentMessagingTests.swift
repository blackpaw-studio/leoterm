import Testing

@testable import LeoKit

struct LeoAgentMessagingTests {
    static let zeusOnStudio = LeoAgentTarget(machineID: "d1", machineName: "Studio", agent: "zeus")
    static let zeusOnLaptop = LeoAgentTarget(machineID: "d2", machineName: "Laptop", agent: "zeus")
    static let hera = LeoAgentTarget(machineID: "d1", machineName: "Studio", agent: "hera")

    @Test func aConfiguredAgentThatIsPresentIsSentTo() {
        let resolution = LeoAgentResolution.resolve(
            configured: LeoPushTarget(daemonID: "d1", agent: "zeus"),
            available: [Self.zeusOnStudio, Self.hera], machineCount: 1
        )
        #expect(resolution == .send(Self.zeusOnStudio))
    }

    @Test func aConfiguredAgentThatIsGoneAsksAndNamesIt() {
        let resolution = LeoAgentResolution.resolve(
            configured: LeoPushTarget(daemonID: "d1", agent: "ares"),
            available: [Self.zeusOnStudio, Self.hera], machineCount: 1
        )
        #expect(resolution == .ask(options: [Self.zeusOnStudio, Self.hera], unavailable: "ares"))
    }

    @Test func noConfiguredAgentAsksWithoutAnUnavailableName() {
        let resolution = LeoAgentResolution.resolve(configured: nil, available: [Self.hera], machineCount: 1)
        #expect(resolution == .ask(options: [Self.hera], unavailable: nil))
    }

    @Test func noMachinesMeansPairFirstEvenWithAConfiguredAgent() {
        let resolution = LeoAgentResolution.resolve(
            configured: LeoPushTarget(daemonID: "d1", agent: "zeus"), available: [], machineCount: 0
        )
        #expect(resolution == .noMachines)
    }

    @Test func machinesWithNoReachableAgentsStillAskRatherThanPair() {
        let resolution = LeoAgentResolution.resolve(configured: nil, available: [], machineCount: 2)
        #expect(resolution == .ask(options: [], unavailable: nil))
    }

    @Test func theSameNameOnAnotherMachineDoesNotSatisfyAConfiguredTarget() {
        let resolution = LeoAgentResolution.resolve(
            configured: LeoPushTarget(daemonID: "d3", agent: "zeus"),
            available: [Self.zeusOnStudio, Self.zeusOnLaptop], machineCount: 3
        )
        #expect(resolution == .ask(options: [Self.zeusOnStudio, Self.zeusOnLaptop], unavailable: "zeus"))
    }

    @Test func aDuplicateNameShowsItsMachineAndAUniqueNameStaysPlain() {
        let all = [Self.zeusOnStudio, Self.zeusOnLaptop, Self.hera]
        #expect(Self.zeusOnStudio.displayName(among: all) == "zeus · Studio")
        #expect(Self.zeusOnLaptop.displayName(among: all) == "zeus · Laptop")
        #expect(Self.hera.displayName(among: all) == "hera")
    }

    // MARK: Unreachable machines

    static let laptopDown = LeoAgentMachineRef(id: "d2", name: "Laptop")

    @Test func aConfiguredAgentOnAFailedMachineIsStillSentToSoItFailsIntoRetry() {
        let resolution = LeoAgentResolution.resolve(
            configured: LeoPushTarget(daemonID: "d2", agent: "zeus"),
            available: [Self.hera], machineCount: 2, unreachable: [Self.laptopDown]
        )
        #expect(resolution == .send(Self.zeusOnLaptop))
    }

    @Test func nothingAnsweringWhileAMachineFailedIsUnreachableNotAskWithNoOptions() {
        let resolution = LeoAgentResolution.resolve(configured: nil, available: [], machineCount: 1, unreachable: [Self.laptopDown])
        #expect(resolution == .unreachable(configured: nil, machine: "Laptop"))
    }

    @Test func aConfiguredAgentWhoseMachineAnsweredStaysUnavailableEvenIfAnotherMachineFailed() {
        let resolution = LeoAgentResolution.resolve(
            configured: LeoPushTarget(daemonID: "d1", agent: "ares"),
            available: [Self.hera], machineCount: 2, unreachable: [Self.laptopDown]
        )
        #expect(resolution == .ask(options: [Self.hera], unavailable: "ares"))
    }

    @Test func aConfiguredAgentWithNoAnsweringMachineIsUnreachableAndKeepsTheTarget() {
        let configured = LeoPushTarget(daemonID: "d1", agent: "ares")
        let resolution = LeoAgentResolution.resolve(configured: configured, available: [], machineCount: 2, unreachable: [Self.laptopDown])
        #expect(resolution == .unreachable(configured: configured, machine: "Laptop"))
    }

    @Test func aMessageToAnUnreachableConfiguredAgentKeepsItsTextForRetry() {
        let configured = LeoPushTarget(daemonID: "d1", agent: "ares")
        let payload = LeoAgentRetryPayload.forUnreachable(configured: configured, machine: "Laptop", text: "run it")
        #expect(payload == LeoAgentRetryPayload(target: configured, machine: "Laptop", text: "run it"))
    }

    @Test func withNoAgentChosenThereIsNothingToRetryTo() {
        #expect(LeoAgentRetryPayload.forUnreachable(configured: nil, machine: "Laptop", text: "run it") == nil)
    }
}

