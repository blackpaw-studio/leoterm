import Foundation

/// What the user and the agent read about a page's JavaScript dialogs (B-412).
public enum LeoBrowserDialogText {
    /// The most of a page's message the agent reads; the rest is cut.
    public static let maximumAgentMessageLength = 1000

    /// What a leave dialog says. Browsers never show a page's own text
    /// here, so a page can't word it to trick anyone.
    public static let leaveMessage = "Leave this page? Changes you made may not be saved."

    /// The dialog's text as shown: the page's own, or `leaveMessage`.
    public static func message(of dialog: LeoBrowserDialog) -> String {
        dialog.kind == .leave ? leaveMessage : dialog.message
    }

    /// The button an answer stands for.
    public static func buttonTitle(_ kind: LeoBrowserDialogKind, accepted: Bool) -> String {
        switch kind {
        case .alert: "OK"
        case .confirm, .prompt: accepted ? "OK" : "Cancel"
        case .leave: accepted ? "Leave Page" : "Stay on Page"
        }
    }

    // MARK: - The user

    /// "alfred · shop.example.com says:"; `site` in the agent's (remote) terms.
    public static func header(agent: String, site: LeoBrowserSite) -> String {
        "\(agent) · \(site.label) says:"
    }

    public static func detail(agent: String) -> String {
        "The page is paused until you or \(agent) answer."
    }

    /// Shown for a moment after the agent answered the dialog the user saw.
    public static func handledLine(agent: String, answer: LeoBrowserDialogAnswer) -> String {
        "\(agent) answered: \(buttonTitle(answer.dialog.kind, accepted: answer.accepted))"
    }

    // MARK: - The agent

    /// Page text for the agent, cut after `maximumAgentMessageLength` characters.
    public static func capped(_ text: String) -> String {
        text.count > maximumAgentMessageLength ? String(text.prefix(maximumAgentMessageLength)) + "…" : text
    }

    /// Page text for the agent: capped and quoted on one line, so it never
    /// reads as Leo's own words.
    public static func quoted(_ text: String) -> String {
        let capped = capped(text)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(capped)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "\"\""
    }

    /// The `dialog_open` error of a tool that needs the paused page.
    /// `origin` is in the agent's (remote) terms.
    public static func openLine(_ dialog: LeoBrowserDialog, origin: String) -> String {
        "Tab \(dialog.tab) has a \(name(dialog.kind)) open, from \(origin): \(quoted(message(of: dialog))). "
            + "Its page is paused until the dialog is answered, so tools that read or act on the page fail until then. " + howToAnswer(dialog)
    }

    /// The `dialog_open` error of a `browser_dialog` call whose tab's open
    /// dialog is not the one the agent was shown.
    public static func unseenLine(_ dialog: LeoBrowserDialog, origin: String) -> String {
        "Nothing was answered: you hadn't been shown this dialog yet. " + openLine(dialog, origin: origin)
    }

    /// The result of a call that ended early because a dialog opened while it ran.
    public static func openedLine(_ dialog: LeoBrowserDialog, origin: String) -> String {
        "While this call ran, tab \(dialog.tab) opened a \(name(dialog.kind)), from \(origin): \(quoted(message(of: dialog))). "
            + "Its page is paused until the dialog is answered. " + howToAnswer(dialog)
    }

    /// Tells the agent, once, that the user answered a dialog it had been
    /// shown. A prompt's typed text stays with the user.
    public static func handledNote(_ answer: LeoBrowserDialogAnswer) -> String {
        let dialog = answer.dialog
        return "The user answered the \(name(dialog.kind)) in tab \(dialog.tab) (\(quoted(message(of: dialog)))) with "
            + "\(buttonTitle(dialog.kind, accepted: answer.accepted)), in the browser pane."
    }

    /// The `dialog_handled` error: the dialog was answered before this call.
    public static func handledMessage(_ answer: LeoBrowserDialogAnswer) -> String {
        let dialog = answer.dialog
        let button = buttonTitle(dialog.kind, accepted: answer.accepted)
        let how = answer.answerer == .user
            ? "The user already answered the \(name(dialog.kind)) in tab \(dialog.tab) (\(quoted(message(of: dialog)))) with \(button), in the browser pane."
            : "The \(name(dialog.kind)) in tab \(dialog.tab) (\(quoted(message(of: dialog)))) was already answered with \(button) by an earlier browser_dialog call."
        return how + " No dialog is open in tab \(dialog.tab) now."
    }

    /// The `no_dialog` error, pointing at tabs that do have one.
    public static func noDialog(tab: Int, elsewhere: [LeoBrowserDialog]) -> String {
        let others = elsewhere.filter { $0.tab != tab }.map { "tab \($0.tab) has a \(name($0.kind)) open (pass tab: \($0.tab))" }
        let hint = others.isEmpty ? "" : "; " + others.joined(separator: ", ")
        return "No JavaScript dialog is open in tab \(tab)\(hint)."
    }

    static func name(_ kind: LeoBrowserDialogKind) -> String {
        kind == .leave ? "beforeunload dialog" : "JavaScript \(kind.rawValue)"
    }

    private static func howToAnswer(_ dialog: LeoBrowserDialog) -> String {
        let how: String
        switch dialog.kind {
        case .alert:
            how = "Call browser_dialog to press its only button, OK (accept and dismiss both do)."
        case .confirm:
            how = "Call browser_dialog with action accept (OK) or dismiss (Cancel)."
        case .prompt:
            let fallback = dialog.defaultText.flatMap { $0.isEmpty ? nil : "its default \(quoted($0)) is sent" } ?? "an empty answer is sent"
            how = "Call browser_dialog with action accept (OK; pass text to answer, or \(fallback)) or dismiss (Cancel)."
        case .leave:
            how = "Call browser_dialog with action accept (Leave Page) or dismiss (Stay on Page)."
        }
        return how + " The user may answer it first in the browser pane."
    }
}
