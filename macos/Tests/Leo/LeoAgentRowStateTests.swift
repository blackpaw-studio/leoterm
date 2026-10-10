import Foundation
import Testing

@testable import Ghostty

/// An agent row's state resolution (first match wins) and what each state
/// draws: its leading symbol and ink, whether it has a second line, and
/// what trails the name.
struct LeoAgentRowStateTests {
    private func resolve(
        status: LeoAgentStatus = .running, activity: LeoAgentRow.Activity = .idle, attention: LeoAttentionBadge? = nil,
        reason: LeoAttentionReason? = nil, compaction: LeoRowCompaction? = nil, error: String? = nil,
        inWorkingSection: Bool = false
    ) -> LeoAgentRowState {
        let row = LeoAgentRow(
            host: .local, name: "alpha", template: "claude", status: status, activity: activity, actionDetail: nil,
            attention: attention, attentionReason: reason, compaction: compaction
        )
        return LeoAgentRowState(row: row, error: error, inWorkingSection: inWorkingSection)
    }

    // MARK: What each state draws

    @Test func needsYouIsOrangeWithTheReasonSymbolAndAnOrangeSecondLine() {
        let plain = resolve(attention: .needsInput)
        #expect(plain.state == .needsYou)
        #expect(plain.symbolName == "questionmark.circle.fill")
        #expect(plain.symbolInk == .tint(.orange))
        #expect(plain.hasSecondLine)
        #expect(plain.detailInk == .tint(.orange))
        #expect(plain.trailingWord == nil)
        let symbols: [(LeoAttentionReason.Kind, String)] = [
            (.permission, "hand.raised.fill"), (.question, "questionmark.bubble.fill"), (.elicitation, "list.bullet.rectangle.fill")
        ]
        for (kind, symbol) in symbols {
            #expect(resolve(attention: .needsInput, reason: LeoAttentionReason(kind: kind)).symbolName == symbol)
        }
    }

    @Test func errorIsRedWithARedSecondLine() {
        for resolved in [resolve(attention: .errored), resolve(error: "boom")] {
            #expect(resolved.state == .error)
            #expect(resolved.symbolName == "exclamationmark.triangle.fill")
            #expect(resolved.symbolInk == .tint(.red))
            #expect(resolved.hasSecondLine)
            #expect(resolved.detailInk == .tint(.red))
            #expect(resolved.trailingWord == nil)
        }
        #expect(resolve(error: "").state == .idle, "an empty error is no error")
    }

    @Test func doneIsAGreenCheckWithASecondarySecondLine() {
        let done = resolve(attention: .finished)
        #expect(done.state == .done)
        #expect(done.symbolName == "checkmark.circle")
        #expect(done.symbolInk == .tint(.green))
        #expect(done.hasSecondLine)
        #expect(done.detailInk == .secondary)
        #expect(done.trailingWord == nil)
    }

    @Test func workingIsABlueRotatingSymbolWithASecondLine() {
        for resolved in [resolve(attention: .working), resolve(activity: .working)] {
            #expect(resolved.state == .working)
            #expect(resolved.symbolName == "arrow.triangle.2.circlepath")
            #expect(resolved.symbolInk == .tint(.blue))
            #expect(resolved.rotates)
            #expect(resolved.hasSecondLine)
            #expect(resolved.detailInk == .secondary)
            #expect(resolved.trailingWord == nil)
        }
        #expect(!resolve(attention: .finished).rotates)
    }

    @Test func compactingIsIndigoOneLineWithTheWordTrailing() {
        let compacting = resolve(compaction: LeoRowCompaction(trigger: .auto))
        #expect(compacting.state == .compacting)
        #expect(compacting.symbolName == "arrow.down.right.and.arrow.up.left")
        #expect(compacting.symbolInk == .tint(.indigo))
        #expect(!compacting.hasSecondLine)
        #expect(compacting.trailingWord == "Compacting")
        #expect(compacting.trailingInk == .tint(.indigo))
        #expect(compacting.help == "Compacting context (automatic)")
        #expect(!compacting.rotates)
    }

    @Test func compactionHelpNamesTheTrigger() {
        #expect(resolve(compaction: LeoRowCompaction(trigger: .manual)).help == "Compacting context (requested)")
        #expect(resolve(compaction: LeoRowCompaction(trigger: nil)).help == "Compacting context")
    }

    @Test func startingIsASecondaryEllipsisOnOneLine() {
        let starting = resolve(status: .starting)
        #expect(starting.state == .starting)
        #expect(starting.symbolName == "ellipsis")
        #expect(starting.symbolInk == .secondary)
        #expect(!starting.hasSecondLine)
        #expect(starting.trailingWord == nil)
    }

    @Test func idleIsATertiaryMoonOnOneLine() {
        for resolved in [resolve(), resolve(activity: .unknown)] {
            #expect(resolved.state == .idle)
            #expect(resolved.symbolName == "moon")
            #expect(resolved.symbolInk == .tertiary)
            #expect(!resolved.hasSecondLine)
            #expect(resolved.trailingWord == nil)
        }
    }

    @Test func stoppedIsATertiaryStopOnOneLineAndDimsTheName() {
        let stopped = resolve(status: .stopped)
        #expect(stopped.state == .stopped)
        #expect(stopped.symbolName == "stop.fill")
        #expect(stopped.symbolInk == .tertiary)
        #expect(!stopped.hasSecondLine)
        #expect(stopped.isNameDimmed)
        #expect(!resolve().isNameDimmed)
    }

    @Test func unknownIsATertiaryQuestionMarkOnOneLine() {
        let unknown = resolve(status: .unknown("weird"))
        #expect(unknown.state == .unknown)
        #expect(unknown.symbolName == "questionmark")
        #expect(unknown.symbolInk == .tertiary)
        #expect(!unknown.hasSecondLine)
        #expect(unknown.trailingWord == nil)
    }

    @Test func everyStateHasItsOwnSymbolShape() {
        let all = [
            resolve(attention: .needsInput), resolve(attention: .errored), resolve(attention: .finished),
            resolve(attention: .working), resolve(compaction: LeoRowCompaction(trigger: nil)), resolve(status: .starting),
            resolve(), resolve(status: .stopped), resolve(status: .unknown("x"))
        ]
        #expect(Set(all.map(\.symbolName)).count == all.count, "colour is never the only cue")
    }

    // MARK: Working section (grouped by attention)

    @Test func inTheWorkingSectionWorkingIsOneLineWithTheWordTrailing() {
        let working = resolve(attention: .working, inWorkingSection: true)
        #expect(working.state == .working)
        #expect(!working.hasSecondLine)
        #expect(working.trailingWord == "Working")
        #expect(working.trailingInk == .tint(.blue))
        let compacting = resolve(compaction: LeoRowCompaction(trigger: nil), inWorkingSection: true)
        #expect(!compacting.hasSecondLine)
        #expect(compacting.trailingWord == "Compacting")
    }

    @Test func theWorkingSectionFlagLeavesOtherStatesAlone() {
        #expect(resolve(attention: .finished, inWorkingSection: true).hasSecondLine)
        #expect(resolve(inWorkingSection: true).trailingWord == nil)
    }

    // MARK: Precedence

    @Test func precedenceFollowsTheTableOrder() {
        #expect(resolve(status: .stopped, attention: .needsInput, error: "x").state == .needsYou)
        #expect(resolve(attention: .working, error: "x").state == .error)
        #expect(resolve(attention: .finished, compaction: LeoRowCompaction(trigger: nil)).state == .done)
        #expect(resolve(status: .starting, activity: .working, compaction: LeoRowCompaction(trigger: nil)).state == .starting)
        #expect(resolve(status: .stopped, activity: .working).state == .stopped)
        #expect(resolve(activity: .working, compaction: LeoRowCompaction(trigger: nil)).state == .compacting)
    }

    // MARK: VoiceOver

    @Test func voiceOverSpeaksTheReasonWhenThereIsOne() {
        let reason = LeoAttentionReason(kind: .permission, tool: "Bash", detail: "rm")
        let asking = resolve(attention: .needsInput, reason: reason)
        #expect(asking.accessibilityLabel == "Needs Permission, Bash")
        #expect(asking.help == "Needs permission to use Bash: rm")
        #expect(resolve(attention: .needsInput).accessibilityLabel == "Needs you")
        #expect(resolve(status: .stopped).accessibilityLabel == "Stopped")
        #expect(resolve(attention: .finished).accessibilityLabel == "Done")
        #expect(resolve(attention: .working, inWorkingSection: true).accessibilityLabel == "Working")
    }
}
