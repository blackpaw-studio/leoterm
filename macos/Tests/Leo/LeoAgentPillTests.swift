import Foundation
import Testing

@testable import Ghostty

/// The state pill's resolution table: first matching row wins.
struct LeoAgentPillTests {
    private func pill(
        status: LeoAgentStatus = .running, activity: LeoAgentRow.Activity = .idle, attention: LeoAttentionBadge? = nil,
        reason: LeoAttentionReason? = nil, compaction: LeoRowCompaction? = nil, error: String? = nil
    ) -> LeoAgentPill {
        let row = LeoAgentRow(
            host: .local, name: "alpha", template: "claude", status: status, activity: activity, actionDetail: nil,
            attention: attention, attentionReason: reason, compaction: compaction
        )
        return LeoAgentPill(row: row, error: error)
    }

    @Test func needsInputIsOrangeWithTheReasonSymbol() {
        let plain = pill(attention: .needsInput)
        #expect(plain.state == .needsYou)
        #expect(plain.word == "Needs you")
        #expect(plain.symbolName == "questionmark.circle")
        #expect(plain.tint == .orange)
        let symbols: [(LeoAttentionReason.Kind, String)] = [
            (.permission, "hand.raised"), (.question, "questionmark.bubble"), (.elicitation, "list.bullet.rectangle")
        ]
        for (kind, symbol) in symbols {
            #expect(pill(attention: .needsInput, reason: LeoAttentionReason(kind: kind)).symbolName == symbol)
        }
    }

    @Test func erroredAttentionOrARowErrorIsRed() {
        for resolved in [pill(attention: .errored), pill(error: "boom")] {
            #expect(resolved.state == .error)
            #expect(resolved.word == "Error")
            #expect(resolved.symbolName == "exclamationmark.triangle.fill")
            #expect(resolved.tint == .red)
        }
        #expect(pill(error: "").state == .idle, "an empty error is no error")
    }

    @Test func finishedIsGreen() {
        let done = pill(attention: .finished)
        #expect(done.state == .done)
        #expect([done.word, done.symbolName] == ["Done", "checkmark"])
        #expect(done.tint == .green)
    }

    @Test func lifecycleStatusesOutsideRunning() {
        let starting = pill(status: .starting)
        #expect([starting.word, starting.symbolName] == ["Starting", "ellipsis"])
        #expect(starting.tint == .gray)
        let stopped = pill(status: .stopped)
        #expect([stopped.word, stopped.symbolName] == ["Stopped", "stop.fill"])
        #expect(stopped.tint == .gray)
        #expect(stopped.isOutlined)
        let unknown = pill(status: .unknown("weird"))
        #expect([unknown.word, unknown.symbolName] == ["Unknown", "questionmark"])
        #expect(!starting.isOutlined && !unknown.isOutlined)
    }

    @Test func compactionIsIndigo() {
        let compacting = pill(compaction: LeoRowCompaction(trigger: .auto))
        #expect(compacting.state == .compacting)
        #expect(compacting.word == "Compacting")
        #expect(compacting.symbolName == "arrow.down.right.and.arrow.up.left")
        #expect(compacting.tint == .indigo)
        #expect(compacting.help == "Compacting context (automatic)")
    }

    @Test func compactionHelpNamesTheTrigger() {
        #expect(pill(compaction: LeoRowCompaction(trigger: .manual)).help == "Compacting context (requested)")
        #expect(pill(compaction: LeoRowCompaction(trigger: nil)).help == "Compacting context")
    }

    @Test func workingComesFromAttentionOrActivity() {
        for resolved in [pill(attention: .working), pill(activity: .working)] {
            #expect(resolved.state == .working)
            #expect(resolved.word == "Working")
            #expect(resolved.symbolName == "gearshape")
            #expect(resolved.tint == .blue)
        }
    }

    @Test func otherwiseIdle() {
        for resolved in [pill(), pill(activity: .unknown)] {
            #expect(resolved.state == .idle)
            #expect([resolved.word, resolved.symbolName] == ["Idle", "moon.fill"])
            #expect(resolved.tint == .gray)
        }
    }

    @Test func precedenceFollowsTheTableOrder() {
        #expect(pill(status: .stopped, attention: .needsInput, error: "x").state == .needsYou)
        #expect(pill(attention: .working, error: "x").state == .error)
        #expect(pill(attention: .finished, compaction: LeoRowCompaction(trigger: nil)).state == .done)
        #expect(pill(status: .starting, activity: .working, compaction: LeoRowCompaction(trigger: nil)).state == .starting)
        #expect(pill(status: .stopped, activity: .working).state == .stopped)
        #expect(pill(activity: .working, compaction: LeoRowCompaction(trigger: nil)).state == .compacting)
    }

    @Test func voiceOverSpeaksTheReasonWhenThereIsOne() {
        let reason = LeoAttentionReason(kind: .permission, tool: "Bash", detail: "rm")
        let asking = pill(attention: .needsInput, reason: reason)
        #expect(asking.accessibilityLabel == "Needs Permission, Bash")
        #expect(asking.help == "Needs permission to use Bash: rm")
        #expect(pill(attention: .needsInput).accessibilityLabel == "Needs you")
        #expect(pill(status: .stopped).accessibilityLabel == "Stopped")
    }
}
