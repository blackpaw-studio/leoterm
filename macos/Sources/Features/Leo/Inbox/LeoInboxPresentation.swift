import AppKit
import Foundation
import LeoKit

/// What the inbox says, as pure functions of its items.
enum LeoInboxPresentation {
    /// "3 need you · 3 finished since you looked"; "You're all caught up" when neither.
    static func summary(_ summary: LeoInboxSummary) -> String {
        var parts: [String] = []
        if summary.needYou > 0 { parts.append("\(summary.needYou) need\(summary.needYou == 1 ? "s" : "") you") }
        if summary.unreadFinished > 0 { parts.append("\(summary.unreadFinished) finished since you looked") }
        return parts.isEmpty ? "You're all caught up" : parts.joined(separator: " · ")
    }

    /// "now", "4m", "2h", "3d": how long ago `date` was.
    static func age(of date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }

    /// Where the item came from: "Leo Chat", "Permission prompt", "Question", or nothing for a finished one.
    static func sourceLabel(_ kind: LeoInboxKind) -> String? {
        switch kind {
        case .chatAsk(let message): message.kind == .permission ? "Leo Chat · permission" : "Leo Chat"
        case .permission: "Permission prompt"
        case .question: "Question"
        case .finished: nil
        }
    }

    /// The row's second line: the question, `Tool · command`, the result.
    static func headline(_ item: LeoInboxItem) -> String {
        switch item.kind {
        case .chatAsk(let message):
            let text = message.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Waiting for your answer" : text
        case .permission(let tool, let detail, let input):
            return [tool, input ?? detail].compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }.joined(separator: " · ").nonEmpty ?? "Permission prompt"
        case .question(let text):
            return text.flatMap { $0.isEmpty ? nil : $0 } ?? "Waiting for your input"
        case .finished(let result):
            return result.flatMap { $0.isEmpty ? nil : $0 } ?? (item.isError ? "Stopped with an error" : "Finished")
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// A key the inbox acts on while it has the keyboard.
enum LeoInboxKeyAction: Equatable {
    case moveUp, moveDown, submit, goToAgent, dismissItem

    private static let keyCodes: [UInt16: LeoInboxKeyAction] = [126: .moveUp, 125: .moveDown, 36: .submit, 76: .submit, 51: .dismissItem, 117: .dismissItem]
    private static let returnCodes: Set<UInt16> = [36, 76]

    /// ↑/↓ move, ↩ submits, ⌘↩ goes to the agent, ⌫ dismisses (blocked) or
    /// clears (finished) the item. Any other modifier (⇧⌃⌥, or ⌘ with another
    /// key) is not the inbox's.
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> LeoInboxKeyAction? {
        let held = modifiers.intersection([.shift, .control, .option, .command])
        if held == .command { return returnCodes.contains(keyCode) ? .goToAgent : nil }
        guard held.isEmpty else { return nil }
        return keyCodes[keyCode]
    }
}
