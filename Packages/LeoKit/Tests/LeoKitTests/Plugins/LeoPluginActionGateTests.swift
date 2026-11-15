import Foundation
import Testing

@testable import LeoKit

struct LeoPluginActionGateTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let agent = LeoPluginAgentRef(machine: "local", name: "alfred")

    private var send: LeoPluginAction { .sendToAgent(agent: agent, text: "run the tests") }
    private var spawn: LeoPluginAction {
        .spawnAgent(LeoPluginSpawnSpec(repo: "a/b", branch: "fix", base: nil, prompt: "go", machine: nil))
    }

    private func gate(
        _ verbs: Set<LeoPluginAgentVerb> = [.read, .send, .spawn],
        clock: LeoPluginLaneCClock
    ) -> LeoPluginActionGate {
        LeoPluginActionGate(grants: verbs, now: { clock.now })
    }

    private func click(_ clock: LeoPluginLaneCClock) -> LeoPluginGesture {
        LeoPluginGesture(origin: .click, mintedAt: clock.now)
    }

    // MARK: send / spawn need a gesture

    @Test(arguments: [true, false])
    func sendAndSpawnWithoutGestureAreRefused(isSend: Bool) {
        let clock = LeoPluginLaneCClock(t0)
        let result = gate(clock: clock).authorize(isSend ? send : spawn, gesture: nil)
        #expect(result == .failure(.missingGesture))
    }

    @Test(arguments: [true, false])
    func sendAndSpawnWithGestureNeedConfirmation(isSend: Bool) {
        let clock = LeoPluginLaneCClock(t0)
        let action = isSend ? send : spawn
        let result = gate(clock: clock).authorize(action, gesture: click(clock))
        #expect(result == .success(.confirm(action)))
    }

    @Test func missingPermissionIsRefusedEvenWithGesture() {
        let clock = LeoPluginLaneCClock(t0)
        let readOnly = gate([.read], clock: clock)
        #expect(readOnly.authorize(send, gesture: click(clock)) == .failure(.permissionDenied(.send)))
        #expect(readOnly.authorize(spawn, gesture: click(clock)) == .failure(.permissionDenied(.spawn)))
        let sendOnly = gate([.send], clock: clock)
        #expect(sendOnly.authorize(spawn, gesture: click(clock)) == .failure(.permissionDenied(.spawn)))
    }

    @Test func gestureCannotBeReused() {
        let clock = LeoPluginLaneCClock(t0)
        let gate = gate(clock: clock)
        let token = click(clock)
        #expect(gate.authorize(send, gesture: token) == .success(.confirm(send)))
        #expect(gate.authorize(send, gesture: token) == .failure(.gestureAlreadyUsed))
        #expect(gate.authorize(spawn, gesture: token) == .failure(.gestureAlreadyUsed))
    }

    @Test func gestureExpiresAfterThirtySeconds() {
        let clock = LeoPluginLaneCClock(t0)
        let gate = gate(clock: clock)
        let token = click(clock)
        clock.advance(30)
        #expect(gate.authorize(send, gesture: token) == .success(.confirm(send)))
        let stale = click(clock)
        clock.advance(30.5)
        #expect(gate.authorize(send, gesture: stale) == .failure(.expiredGesture))
    }

    @Test func invalidTargetsAreRefused() {
        let clock = LeoPluginLaneCClock(t0)
        let gate = gate(clock: clock)
        let noName = LeoPluginAction.sendToAgent(agent: LeoPluginAgentRef(machine: "local", name: ""), text: "x")
        let noRepo = LeoPluginAction.spawnAgent(LeoPluginSpawnSpec(repo: "", branch: "b", base: nil, prompt: "p", machine: nil))
        #expect(gate.authorize(noName, gesture: click(clock)) == .failure(.invalidTarget))
        #expect(gate.authorize(noRepo, gesture: click(clock)) == .failure(.invalidTarget))
    }

    @Test func gestureIsNeverDecodableFromWire() throws {
        // A plugin that smuggles gesture-shaped data into an action gets nothing.
        let json = """
        {"type":"sendToAgent","agent":{"machine":"local","name":"alfred"},"text":"hi",
         "gesture":{"origin":"click","mintedAt":1000000}}
        """
        let decoded = try JSONDecoder().decode(LeoPluginAction.self, from: Data(json.utf8))
        let clock = LeoPluginLaneCClock(t0)
        #expect(gate(clock: clock).authorize(decoded, gesture: nil) == .failure(.missingGesture))
    }

    // MARK: non-agent actions

    @Test func httpsOpenURLIsPerformed() {
        let clock = LeoPluginLaneCClock(t0)
        let action = LeoPluginAction.openURL("https://github.com/a/b/pull/1")
        #expect(gate(clock: clock).authorize(action, gesture: nil) == .success(.perform(action)))
    }

    @Test(arguments: [
        "http://github.com", "javascript:alert(1)", "file:///etc/passwd", "leo://x",
        "https://user:pw@github.com", "https://", "not a url", "",
    ])
    func nonHTTPSOpenURLIsRefused(url: String) {
        let clock = LeoPluginLaneCClock(t0)
        let result = gate(clock: clock).authorize(.openURL(url), gesture: click(clock))
        #expect(result == .failure(.insecureURL))
    }

    @Test func callbackPushViewAndCopyArePerformed() {
        let clock = LeoPluginLaneCClock(t0)
        let gate = gate([], clock: clock)
        for action in [
            LeoPluginAction.callback(id: "refresh", payload: .null),
            .pushView(node: .loading(.init(message: nil))),
            .copy("text"),
        ] {
            #expect(gate.authorize(action, gesture: nil) == .success(.perform(action)))
        }
    }

    // MARK: follow-ups from callbacks

    @Test func followUpWithoutOriginGestureIsDropped() {
        let clock = LeoPluginLaneCClock(t0)
        let gate = gate(clock: clock)
        #expect(gate.authorizeFollowUp(send, originGesture: nil) == .failure(.missingGesture))
        #expect(gate.authorizeFollowUp(.copy("x"), originGesture: nil) == .failure(.missingGesture))
    }

    @Test func gestureFollowUpGoesThroughConfirmationOnce() {
        let clock = LeoPluginLaneCClock(t0)
        let gate = gate(clock: clock)
        let token = click(clock)
        clock.advance(12) // async fetch took a while
        #expect(gate.authorizeFollowUp(spawn, originGesture: token) == .success(.confirm(spawn)))
        #expect(gate.authorizeFollowUp(send, originGesture: token) == .failure(.gestureAlreadyUsed))
    }

    @Test func followUpAfterThirtySecondsIsDropped() {
        let clock = LeoPluginLaneCClock(t0)
        let gate = gate(clock: clock)
        let token = click(clock)
        clock.advance(31)
        #expect(gate.authorizeFollowUp(send, originGesture: token) == .failure(.expiredGesture))
    }

    @Test func followUpStillNeedsPermission() {
        let clock = LeoPluginLaneCClock(t0)
        let readOnly = gate([.read], clock: clock)
        #expect(readOnly.authorizeFollowUp(send, originGesture: click(clock)) == .failure(.permissionDenied(.send)))
    }

    // MARK: wire

    @Test func actionsRoundTrip() throws {
        let actions: [LeoPluginAction] = [
            .callback(id: "x", payload: .object(["n": .int(1)])),
            .pushView(node: .loading(.init(message: nil))),
            .openURL("https://example.com"),
            .copy("hello"),
            send,
            .spawnAgent(LeoPluginSpawnSpec(repo: "a/b", branch: "c", base: "main", prompt: "p", machine: "m")),
        ]
        for action in actions {
            let data = try JSONEncoder().encode(action)
            #expect(try JSONDecoder().decode(LeoPluginAction.self, from: data) == action)
        }
    }

    @Test func unknownActionTypeFailsToDecode() {
        let json = Data(#"{"type":"runShell","cmd":"ls"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LeoPluginAction.self, from: json) }
    }
}

/// Injected clock shared by the plugin tests. Reference type so closures see advances.
final class LeoPluginLaneCClock: @unchecked Sendable {
    private(set) var now: Date
    init(_ start: Date) { now = start }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
