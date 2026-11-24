import Foundation
import Testing

@testable import LeoKit

/// The inbox's additions to the attention contract: `attention.preview` (the
/// one-line result), `attention.at` (daemon clock) and the reducer's
/// `committedSignal(for:)`.
struct LeoAttentionInboxSignalTests {
    private static let host = LeoHostID.remote("mars")

    private func decode(_ json: String) throws -> LeoAttentionSignal {
        try JSONDecoder().decode(LeoAttentionSignal.self, from: Data(json.utf8))
    }

    private func live(_ baseline: [String: LeoAttentionSignal] = [:]) -> LeoAttentionReducer {
        var reducer = LeoAttentionReducer()
        reducer.switchHost(Self.host)
        reducer.applyBaseline(baseline)
        return reducer
    }

    @Test func previewAndAtDecodeWhenPresent() throws {
        let signal = try decode(#"{"state":"finished","revision":3,"preview":"Shipped the fix","at":"2026-11-24T17:00:00Z"}"#)

        #expect(signal.preview == "Shipped the fix")
        #expect(signal.at == Date(timeIntervalSince1970: 1_795_539_600))
    }

    @Test func fractionalSecondsAndOffsetsInAtDecode() throws {
        let signal = try decode(#"{"state":"finished","revision":3,"at":"2026-11-24T12:00:00.500-05:00"}"#)
        #expect(signal.at == Date(timeIntervalSince1970: 1_795_539_600.5))
    }

    @Test func absentFieldsReadAsNil() throws {
        let signal = try decode(#"{"state":"finished","revision":3}"#)
        #expect(signal.preview == nil)
        #expect(signal.at == nil)
    }

    @Test func malformedAtIsNilWithoutDroppingTheSignal() throws {
        let signal = try decode(#"{"state":"errored","revision":4,"at":"yesterday","preview":"boom"}"#)
        #expect(signal.at == nil)
        #expect(signal.state == .errored)
        #expect(signal.preview == "boom")
    }

    @Test func wrongTypedPreviewAndAtReadAsNil() throws {
        let signal = try decode(#"{"state":"finished","revision":4,"at":12,"preview":["x"]}"#)
        #expect(signal.at == nil)
        #expect(signal.preview == nil)
    }

    @Test func previewIsSanitizedAndClamped() {
        let long = String(repeating: "x", count: LeoAttentionSignal.previewLimit + 50)
        let signal = LeoAttentionSignal(state: .finished, revision: 1, preview: long)

        #expect(signal.preview?.count == LeoAttentionSignal.previewLimit)
        #expect(signal.preview?.hasSuffix("…") == true)
        #expect(LeoAttentionSignal(state: .finished, revision: 1, preview: "  \n ").preview == nil)
    }

    @Test func committedSignalIsTheLiveCommittedOne() {
        var reducer = live()
        #expect(reducer.committedSignal(for: "alpha") == nil)

        let signal = LeoAttentionSignal(state: .finished, revision: 2, preview: "done")
        reducer.receive(agent: "alpha", signal: signal, now: 0)
        #expect(reducer.committedSignal(for: "alpha") == nil, "still settling")
        _ = reducer.tick(now: 0.3)

        #expect(reducer.committedSignal(for: "alpha") == signal)
    }

    @Test func committedSignalIsNilForAStaleHost() {
        var reducer = live(["alpha": LeoAttentionSignal(state: .finished, revision: 2)])
        reducer.disconnect()
        #expect(reducer.committedSignal(for: "alpha") == nil)
    }

    @Test func erroredNotifiesLikeFinished() {
        var reducer = live()
        reducer.receive(agent: "a", signal: LeoAttentionSignal(state: .errored, revision: 1), now: 0)
        reducer.receive(agent: "b", signal: LeoAttentionSignal(state: .finished, revision: 1), now: 0)
        reducer.receive(agent: "c", signal: LeoAttentionSignal(state: .working, revision: 1), now: 0)

        #expect(reducer.tick(now: 0.3).filter(\.shouldNotify).map(\.id.name) == ["a", "b"])
    }

    @Test func aPermissionReasonCarriesTheFullCommandInput() throws {
        let signal = try decode(#"{"state":"needs_input","revision":2,"reason":{"kind":"permission","tool":"Bash","detail":"short","input":"nomad job run x.nomad"}}"#)
        #expect(signal.reason?.input == "nomad job run x.nomad")
        #expect(signal.reason?.detail == "short")
    }

    @Test func reasonInputIsSingleLineAndClampedTo500() throws {
        let long = String(repeating: "a", count: 700)
        let reason = try JSONDecoder().decode(
            LeoAttentionReason.self, from: Data(#"{"kind":"permission","input":"echo\nhi\u001b[31m \#(long)"}"#.utf8)
        )
        let input = try #require(reason.input)
        #expect(!input.contains("\n") && !input.contains("\u{1b}"))
        #expect(input.count == LeoAttentionReason.inputLimit)
        #expect(input.hasSuffix("…"))
    }

    @Test func reasonInputKeepsQuotesAsSent() {
        let reason = LeoAttentionReason(kind: .permission, input: #"git commit -m "fix: it's done""#)
        #expect(reason.input == #"git commit -m "fix: it's done""#)
    }

    @Test func reasonInputIsAbsentFromOldDaemonsAndIgnoredOnOtherKinds() throws {
        #expect(try decode(#"{"state":"needs_input","revision":2,"reason":{"kind":"permission","tool":"Bash"}}"#).reason?.input == nil)
        let question = try decode(#"{"state":"needs_input","revision":2,"reason":{"kind":"question","detail":"Q","input":"x"}}"#)
        #expect(question.reason?.input == nil)
    }

    @Test func theCommittedBootIDIsExposedAndResetsWithTheHost() {
        var reducer = live()
        #expect(reducer.bootID == nil)
        _ = reducer.observeBoot("boot-1")
        #expect(reducer.bootID == "boot-1")
        _ = reducer.observeBoot("boot-2")
        #expect(reducer.bootID == "boot-2")
        reducer.switchHost(.local)
        #expect(reducer.bootID == nil)
    }
}
