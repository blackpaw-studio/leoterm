import Testing

@testable import LeoKit

struct LeoBrowserControlTests {
    private let handoff = LeoBrowserControl.handoff(requestID: "r1", message: "Log in")

    @Test func startsWithTheAgentDriving() {
        #expect(LeoBrowserControl.initial == .agent)
        #expect(LeoBrowserControl.agent.isAgentDriving)
        #expect(!LeoBrowserControl.user.isAgentDriving)
        #expect(!handoff.isAgentDriving)
    }

    @Test func userInputTakesControlFromTheAgentAndIsHarmlessOtherwise() {
        #expect(LeoBrowserControl.agent.applying(.userInput).state == .user)
        #expect(LeoBrowserControl.user.applying(.userInput).state == .user)
        #expect(handoff.applying(.userInput).state == handoff)
    }

    @Test func clickingThePillTakesControlLikeInput() {
        #expect(LeoBrowserControl.agent.applying(.pill).state == .user)
        #expect(LeoBrowserControl.user.applying(.pill).state == .user)
        #expect(handoff.applying(.pill).state == handoff)
    }

    @Test func giveBackReturnsControlButNeverEndsAHandoff() {
        #expect(LeoBrowserControl.user.applying(.giveBack).state == .agent)
        #expect(LeoBrowserControl.agent.applying(.giveBack).state == .agent)
        let result = handoff.applying(.giveBack)
        #expect(result.state == handoff)
        #expect(result.effect == nil)
    }

    @Test func aHandoffRequestSwitchesToHandoffFromAnyState() {
        for start in [LeoBrowserControl.agent, .user] {
            let result = start.applying(.handoff(requestID: "r1", message: "Log in"))
            #expect(result.state == handoff)
            #expect(result.effect == nil)
        }
    }

    @Test func aSecondHandoffDeclinesTheFirstAndReplacesIt() {
        let result = handoff.applying(.handoff(requestID: "r2", message: "Captcha"))
        #expect(result.state == .handoff(requestID: "r2", message: "Captcha"))
        #expect(result.effect == .settle(requestID: "r1", outcome: .declined))
    }

    @Test func doneSettlesTheHandoffAsDoneAndGivesControlBack() {
        let result = handoff.applying(.done(requestID: "r1"))
        #expect(result.state == .agent)
        #expect(result.effect == .settle(requestID: "r1", outcome: .done))
    }

    @Test func declineSettlesTheHandoffAsDeclinedAndGivesControlBack() {
        let result = handoff.applying(.decline(requestID: "r1"))
        #expect(result.state == .agent)
        #expect(result.effect == .settle(requestID: "r1", outcome: .declined))
    }

    @Test func doneAndDeclineForAnotherRequestOrOutsideAHandoffDoNothing() {
        for event in [LeoBrowserControl.Event.done(requestID: "other"), .decline(requestID: "other")] {
            let result = handoff.applying(event)
            #expect(result.state == handoff)
            #expect(result.effect == nil)
        }
        for state in [LeoBrowserControl.agent, .user] {
            #expect(state.applying(.done(requestID: "r1")).state == state)
            #expect(state.applying(.done(requestID: "r1")).effect == nil)
        }
    }

    @Test func cancelledDropsTheBannerButLeavesTheUserInControl() {
        let result = handoff.applying(.cancelled(requestID: "r1"))
        #expect(result.state == .user)
        #expect(result.effect == nil)
    }

    @Test func cancelledForAnotherRequestChangesNothing() {
        #expect(handoff.applying(.cancelled(requestID: "other")).state == handoff)
        #expect(LeoBrowserControl.agent.applying(.cancelled(requestID: "r1")).state == .agent)
        #expect(LeoBrowserControl.user.applying(.cancelled(requestID: "r1")).state == .user)
    }

    @Test func theAgentMayChangeThePageOnlyWhileItIsDriving() {
        #expect(LeoBrowserControl.agent.allowsAgentActions)
        #expect(!LeoBrowserControl.user.allowsAgentActions)
        #expect(!handoff.allowsAgentActions)
    }

    @Test func pendingHandoffExposesItsRequest() {
        #expect(handoff.pendingHandoff?.requestID == "r1")
        #expect(handoff.pendingHandoff?.message == "Log in")
        #expect(LeoBrowserControl.user.pendingHandoff == nil)
    }
}
