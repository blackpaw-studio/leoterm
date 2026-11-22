import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

struct LeoAgentMessagingMacTests {
    private struct Unreachable: Error {}

    @Test(arguments: [LeoHostID.local, .remote("studio"), .remote("a:b")])
    func machineIDRoundTripsToItsHost(host: LeoHostID) {
        #expect(LeoAgentMachineID.host(for: LeoAgentMachineID.id(for: host)) == host)
    }

    @Test(arguments: ["", "remote:", "nope"])
    func unknownMachineIDsAreRejected(id: String) {
        #expect(LeoAgentMachineID.host(for: id) == nil)
    }

    @Test func disconnectedHostIsPairedButListsNoAgents() async {
        let machines = LeoAgentMachine.machines(hosts: [.local, .remote("studio")]) { _ in nil }

        #expect(machines.map(\.name) == ["This Mac", "studio"])
        await #expect(throws: LeoAgentMachineUnavailable.self) { try await machines[1].agents() }
    }

    @Test func retryThatFailsAgainPostsTheSameTextAgain() async {
        let posted = PostedNotifications()
        let machine = LeoAgentMachine(id: "local", name: "This Mac") { [] }
        let sender = LeoAgentMessageSender(machines: { [machine] }, chat: { _ in throw Unreachable() })
        let retry = LeoSendFailedRetry(sender: sender, post: { await posted.add($0) })

        await retry.retry(LeoPushTarget(daemonID: "local", agent: "alfred"), text: "ship it")

        let notifications = await posted.all
        #expect(notifications.count == 1)
        #expect(notifications.first?.userInfo[LeoPushNotification.retryTextKey] == "ship it")
    }

    @Test func retryForAnUnknownMachineSendsNothing() async {
        let posted = PostedNotifications()
        let sender = LeoAgentMessageSender(machines: { [] }, chat: { _ in throw Unreachable() })
        let retry = LeoSendFailedRetry(sender: sender, post: { await posted.add($0) })

        await retry.retry(LeoPushTarget(daemonID: "garbage", agent: "alfred"), text: "hi")

        #expect(await posted.all.isEmpty)
    }

    @Test func nonRetryActionsAreLeftAlone() {
        let sender = LeoAgentMessageSender(machines: { [] }, chat: { _ in throw Unreachable() })
        let retry = LeoSendFailedRetry(sender: sender, post: { _ in })

        #expect(!retry.handle(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: [:]))
    }
}

private actor PostedNotifications {
    private(set) var all: [LeoChatLocalNotification] = []
    func add(_ notification: LeoChatLocalNotification) { all.append(notification) }
}
