import Foundation
import Testing

@testable import Ghostty

/// B-262: drafts, in-flight, inline feedback and per-host denial behind the
/// control bar, against a stub transport (never a real agent).
@MainActor @Suite(.timeLimit(.minutes(1)))
struct LeoAgentControlModelTests {
    private static let row = LeoAgentRow(host: .local, name: "alpha", template: nil, status: .running, activity: .idle, actionDetail: nil)
    private static let ok = #"{"ok":true,"data":{"transport":"bridge"}}"#

    private func make(
        _ transport: ControlModelTransport, confirm: @escaping (LeoAgentRow) async -> Bool = { _ in true }
    ) -> LeoAgentControlModel {
        LeoAgentControlModel(
            daemon: LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport), daemonHost: .local,
            confirmClear: { row, _ in await confirm(row) }
        )
    }

    @Test func sendClearsDraftOnSuccess() async {
        let transport = ControlModelTransport(status: 200, body: Self.ok)
        let model = make(transport)
        model.setDraft("  hello  ", for: Self.row.id)
        await model.send(Self.row)
        #expect(model.draft(for: Self.row.id) == "")
        #expect(model.feedback[Self.row.id] == nil)
        #expect(await transport.paths == ["/agents/alpha/message"])
        #expect(await transport.bodies == [#"{"text":"hello"}"#])
    }

    @Test func sendKeepsDraftAndShowsErrorOnFailure() async {
        let transport = ControlModelTransport(status: 503, body: #"{"ok":false,"error":"agent control is unavailable"}"#)
        let model = make(transport)
        model.setDraft("hello", for: Self.row.id)
        await model.send(Self.row)
        #expect(model.draft(for: Self.row.id) == "hello")
        #expect(model.feedback[Self.row.id] == .error("agent control is unavailable"))
        #expect(model.deniedHosts.isEmpty)
    }

    @Test func queuedClearsDraftAndShowsQuietNotice() async {
        let model = make(ControlModelTransport(status: 202, body: #"{"ok":true,"data":{"queued":true}}"#))
        model.setDraft("hello", for: Self.row.id)
        await model.send(Self.row)
        #expect(model.draft(for: Self.row.id) == "")
        guard case .notice? = model.feedback[Self.row.id] else {
            Issue.record("expected a notice")
            return
        }
    }

    @Test func whitespaceOnlyCannotSend() async {
        let transport = ControlModelTransport(status: 200, body: Self.ok)
        let model = make(transport)
        model.setDraft("  \n ", for: Self.row.id)
        #expect(!model.canSendDraft(for: Self.row.id))
        await model.send(Self.row)
        #expect(await transport.paths.isEmpty)
    }

    @Test func over256KiBShowsInlineErrorWithoutRequest() async {
        let transport = ControlModelTransport(status: 200, body: Self.ok)
        let model = make(transport)
        model.setDraft(String(repeating: "a", count: LeoAgentControlModel.maxMessageBytes + 1), for: Self.row.id)
        await model.send(Self.row)
        #expect(await transport.paths.isEmpty)
        guard case .error? = model.feedback[Self.row.id] else {
            Issue.record("expected an error")
            return
        }
    }

    @Test func forbiddenMarksHostDeniedAndShowsInlineError() async {
        let model = make(ControlModelTransport(status: 403, body: #"{"ok":false,"error":"operator token required"}"#))
        model.setDraft("hi", for: Self.row.id)
        await model.send(Self.row)
        #expect(model.deniedHosts == [.local])
        #expect(model.feedback[Self.row.id] == .error("operator token required"))
        #expect(model.draft(for: Self.row.id) == "hi")
    }

    @Test func unauthorizedAlsoDenies() async {
        let model = make(ControlModelTransport(status: 401, body: #"{"ok":false,"error":"nope"}"#))
        await model.interrupt(Self.row)
        #expect(model.deniedHosts == [.local])
    }

    @Test func deniedHostSendsNothingUntilRetry() async {
        let transport = ControlModelTransport(status: 403, body: #"{"ok":false,"error":"operator token required"}"#)
        let model = make(transport)
        await model.interrupt(Self.row)
        await model.compact(Self.row)
        #expect(await transport.paths.count == 1)
        model.retryAfterDenial(host: .local)
        #expect(model.deniedHosts.isEmpty)
        #expect(model.feedback[Self.row.id] == nil)
        await model.compact(Self.row)
        #expect(await transport.paths.count == 2)
    }

    @Test func hostSwitchClearsErrorsNotDrafts() async {
        let model = make(ControlModelTransport(status: 503, body: #"{"ok":false,"error":"down"}"#))
        model.setDraft("keep me", for: Self.row.id)
        await model.send(Self.row)
        #expect(model.feedback[Self.row.id] != nil)
        let other = LeoSocketDaemonClient(socketPath: "/tmp/other.sock", transport: ControlModelTransport(status: 200, body: Self.ok))
        model.updateDaemon(other, host: .remote("work"))
        #expect(model.feedback.isEmpty)
        #expect(model.draft(for: Self.row.id) == "keep me")
    }

    @Test func secondActionWhileInFlightIsIgnored() async throws {
        let transport = ControlModelTransport(status: 200, body: Self.ok, isGated: true)
        let model = make(transport)
        model.setDraft("hi", for: Self.row.id)
        let first = Task { await model.send(Self.row) }
        try await until { await transport.paths.count == 1 }
        #expect(model.inFlight[Self.row.id] == .message)
        await model.interrupt(Self.row)
        await model.send(Self.row)
        #expect(await transport.paths.count == 1)
        await transport.release()
        await first.value
        #expect(model.inFlight[Self.row.id] == nil)
    }

    @Test func replyAfterHostSwitchIsDropped() async throws {
        let transport = ControlModelTransport(status: 403, body: #"{"ok":false,"error":"operator token required"}"#, isGated: true)
        let model = make(transport)
        let first = Task { await model.interrupt(Self.row) }
        try await until { await transport.paths.count == 1 }
        model.updateDaemon(
            LeoSocketDaemonClient(socketPath: "/tmp/other.sock", transport: ControlModelTransport(status: 200, body: Self.ok)),
            host: .remote("work")
        )
        await transport.release()
        await first.value
        #expect(model.deniedHosts.isEmpty)
        #expect(model.feedback.isEmpty)
    }

    @Test func clearRequiresConfirmation() async {
        let transport = ControlModelTransport(status: 200, body: Self.ok)
        let declined = make(transport, confirm: { _ in false })
        await declined.clear(Self.row)
        #expect(await transport.paths.isEmpty)
        let accepted = make(transport, confirm: { _ in true })
        await accepted.clear(Self.row)
        #expect(await transport.paths == ["/agents/alpha/clear"])
    }

    @Test func typingDuringAnInFlightSendSurvivesSuccess() async throws {
        let transport = ControlModelTransport(status: 200, body: Self.ok, isGated: true)
        let model = make(transport)
        model.setDraft("hi", for: Self.row.id)
        let first = Task { await model.send(Self.row) }
        try await until { await transport.paths.count == 1 }
        model.setDraft("hi there", for: Self.row.id)
        await transport.release()
        await first.value
        #expect(model.draft(for: Self.row.id) == "hi there")
    }

    @Test func queuedNoticeClearsOnTheNextEdit() async {
        let model = make(ControlModelTransport(status: 202, body: #"{"ok":true,"data":{"queued":true}}"#))
        model.setDraft("hello", for: Self.row.id)
        await model.send(Self.row)
        #expect(model.feedback[Self.row.id] != nil)
        model.setDraft("next", for: Self.row.id)
        #expect(model.feedback[Self.row.id] == nil)
    }

    @Test func dismissingFeedbackClearsIt() async {
        let model = make(ControlModelTransport(status: 503, body: #"{"ok":false,"error":"down"}"#))
        await model.interrupt(Self.row)
        #expect(model.feedback[Self.row.id] != nil)
        model.dismissFeedback(for: Self.row.id)
        #expect(model.feedback[Self.row.id] == nil)
    }

    @Test func clearTwiceWhileTheSheetIsOpenAsksOnceAndPostsOnce() async throws {
        let transport = ControlModelTransport(status: 200, body: Self.ok)
        let gate = ConfirmGate()
        let model = make(transport, confirm: { _ in await gate.wait() })
        let first = Task { await model.clear(Self.row) }
        try await until { await gate.calls == 1 }
        await model.clear(Self.row)
        #expect(await gate.calls == 1)
        await gate.release(true)
        await first.value
        #expect(await transport.paths == ["/agents/alpha/clear"])
    }

    @Test func confirmedClearAfterAnotherVerbStartedShowsAnErrorAndDoesNotPost() async throws {
        let transport = ControlModelTransport(status: 200, body: Self.ok, isGated: true)
        let gate = ConfirmGate()
        let model = make(transport, confirm: { _ in await gate.wait() })
        let clear = Task { await model.clear(Self.row) }
        try await until { await gate.calls == 1 }
        let interrupt = Task { await model.interrupt(Self.row) }
        try await until { await transport.paths.count == 1 }
        await gate.release(true)
        await clear.value
        guard case .error? = model.feedback[Self.row.id] else {
            Issue.record("expected an inline error")
            return
        }
        #expect(await transport.paths == ["/agents/alpha/interrupt"])
        await transport.release()
        await interrupt.value
    }

    @Test func confirmedClearAfterDenialShowsAnErrorAndDoesNotPost() async throws {
        let transport = ControlModelTransport(status: 403, body: #"{"ok":false,"error":"operator token required"}"#)
        let gate = ConfirmGate()
        let model = make(transport, confirm: { _ in await gate.wait() })
        let clear = Task { await model.clear(Self.row) }
        try await until { await gate.calls == 1 }
        await model.interrupt(Self.row)
        await gate.release(true)
        await clear.value
        #expect(model.feedback[Self.row.id] == .error(LeoAgentControlAvailability.deniedMessage))
        #expect(await transport.paths == ["/agents/alpha/interrupt"])
    }

    @Test func hostSwitchRoundTripDoesNotAllowADuplicatePost() async throws {
        let transport = ControlModelTransport(status: 200, body: Self.ok, isGated: true)
        let local = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        let model = LeoAgentControlModel(daemon: local, daemonHost: .local, confirmClear: { _, _ in true })
        let first = Task { await model.interrupt(Self.row) }
        try await until { await transport.paths.count == 1 }
        model.updateDaemon(
            LeoSocketDaemonClient(socketPath: "/tmp/other.sock", transport: ControlModelTransport(status: 200, body: Self.ok)),
            host: .remote("work")
        )
        model.updateDaemon(local, host: .local)
        await model.interrupt(Self.row)
        #expect(await transport.paths.count == 1)
        await transport.release()
        await first.value
        #expect(model.inFlight[Self.row.id] == nil)
    }

    @Test func interruptAndCompactHitTheirRoutesImmediately() async {
        let transport = ControlModelTransport(status: 200, body: Self.ok)
        let model = make(transport, confirm: { _ in false })
        await model.interrupt(Self.row)
        await model.compact(Self.row)
        #expect(await transport.paths == ["/agents/alpha/interrupt", "/agents/alpha/compact"])
    }
}

private actor ConfirmGate {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ answer: Bool) {
        continuation?.resume(returning: answer)
        continuation = nil
    }
}

private actor ControlModelTransport: LeoDaemonTransport {
    private(set) var paths: [String] = []
    private(set) var bodies: [String] = []
    private let status: Int
    private let body: Data
    private let isGated: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(status: Int, body: String, isGated: Bool = false) {
        self.status = status
        self.body = Data(body.utf8)
        self.isGated = isGated
    }

    func release() {
        isReleased = true
        gate?.resume()
        gate = nil
    }

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        paths.append(request.path)
        if let data = request.body { bodies.append(String(bytes: data, encoding: .utf8) ?? "") }
        if isGated, !isReleased { await withCheckedContinuation { gate = $0 } }
        return LeoHTTPResponse(status: status, body: body)
    }
}
