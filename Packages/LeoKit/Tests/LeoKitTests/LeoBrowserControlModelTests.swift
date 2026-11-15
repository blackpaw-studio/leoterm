import Testing

@testable import LeoKit

@MainActor
struct LeoBrowserControlModelTests {
    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("condition never held")
    }

    @Test func aRedeliveredHandoffForTheSameRequestJoinsTheFirstAndBothGetTheAnswer() async {
        let model = LeoBrowserControlModel()
        let first = Task { await model.requestHandoff(requestID: "h1", message: "Log in") }
        await settle { model.state.pendingHandoff != nil }
        let second = Task { await model.requestHandoff(requestID: "h1", message: "Log in") }
        for _ in 0..<20 { await Task.yield() }
        #expect(model.state == .handoff(requestID: "h1", message: "Log in"))

        model.send(.done(requestID: "h1"))

        #expect(await first.value == .done)
        #expect(await second.value == .done)
        #expect(model.state == .agent)
    }

    @Test func cancellingOneOfTwoJoinedCallsKeepsTheBannerForTheOther() async {
        let model = LeoBrowserControlModel()
        let first = Task { await model.requestHandoff(requestID: "h1", message: "Log in") }
        await settle { model.state.pendingHandoff != nil }
        let second = Task { await model.requestHandoff(requestID: "h1", message: "Log in") }
        for _ in 0..<20 { await Task.yield() }

        second.cancel()
        #expect(await second.value == nil)
        #expect(model.state.pendingHandoff?.requestID == "h1")

        model.send(.decline(requestID: "h1"))
        #expect(await first.value == .declined)
    }

    @Test func cancellingTheLastJoinedCallDismissesTheBanner() async {
        let model = LeoBrowserControlModel()
        let call = Task { await model.requestHandoff(requestID: "h1", message: "Log in") }
        await settle { model.state.pendingHandoff != nil }
        call.cancel()
        #expect(await call.value == nil)
        #expect(model.state == .user)
    }
}
