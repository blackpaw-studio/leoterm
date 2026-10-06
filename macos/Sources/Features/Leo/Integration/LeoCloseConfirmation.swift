import Foundation

/// B-088: what a "Close …?" confirm for a busy terminal says. It names
/// the pane or row it closes, as the window title and sidebar row name it,
/// so a confirm beside a split isn't ambiguous about which one goes.
enum LeoCloseConfirmation {
    /// The longest name the message quotes; longer ones lose their middle.
    static let maxNameLength = 60

    /// ⌘W on one of a split's panes: only that pane goes.
    static let paneInformativeText = "The terminal in this split still has a running process. "
        + "If you close it, the process will be killed. The other splits stay open."

    /// ⌘W on a terminal row with no split: the row goes.
    static let rowInformativeText = "The terminal still has a running process. "
        + "If you close the terminal the process will be killed."

    /// A pane's name: its title as the window shows it (an attach's agent
    /// name, unless the user set a title -- `LeoTitleSource`), tidied as
    /// its sidebar row reads it (`LeoTerminalRow.displayTitle`). The title
    /// is whatever the terminal sent, so control characters become spaces
    /// and a long one is shortened in the middle, keeping both ends.
    static func name(title: String, isUserSet: Bool, agentName: String?) -> String {
        let shown = LeoTitleSource.resolve(terminalTitle: title, isUserSet: isUserSet, agentName: agentName).title
        return shortened(LeoTerminalRow.displayTitle(of: singleLine(shown)))
    }

    /// "Close “build”?", naming each terminal that closes: two by name,
    /// more by count. Upstream's "Close Terminal?" when none is named.
    static func messageText(closing names: [String]) -> String {
        switch names.count {
        case 0: "Close Terminal?"
        case 1: "Close \(quoted(names[0]))?"
        case 2: "Close \(quoted(names[0])) and \(quoted(names[1]))?"
        default: "Close \(quoted(names[0])) and \(names.count - 1) other terminals?"
        }
    }

    private static func quoted(_ name: String) -> String { "“\(name)”" }

    private static func singleLine(_ title: String) -> String {
        title.unicodeScalars.reduce(into: "") { line, scalar in
            guard isLineBreakingControl(scalar) else {
                line.unicodeScalars.append(scalar)
                return
            }
            if line.last != " " { line.append(" ") }
        }
    }

    /// Keep visible formatting such as an emoji ZWJ sequence. Terminal OSC
    /// titles can still contain C0/C1 controls and Unicode line separators,
    /// which do not belong in a single-line alert.
    private static func isLineBreakingControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0 ... 0x1F, 0x7F ... 0x9F, 0x2028, 0x2029:
            true
        default:
            false
        }
    }

    private static func shortened(_ name: String) -> String {
        guard name.count > maxNameLength else { return name }
        let kept = maxNameLength - 1
        let head = (kept + 1) / 2
        return String(name.prefix(head)) + "…" + String(name.suffix(kept - head))
    }
}
