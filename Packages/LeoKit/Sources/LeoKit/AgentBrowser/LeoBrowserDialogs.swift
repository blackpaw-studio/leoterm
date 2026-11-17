import Foundation

/// Which JavaScript dialog a page opened (B-412). The raw value is what
/// the agent reads.
public enum LeoBrowserDialogKind: String, Sendable, CaseIterable {
    case alert, confirm, prompt
    /// A `beforeunload` "Leave this page?" dialog.
    case leave = "beforeunload"
}

/// A JavaScript dialog a page waits on. The page is paused until it is
/// answered.
public struct LeoBrowserDialog: Equatable, Sendable, Identifiable {
    /// Tells this dialog from a later one in the same tab, so an answer
    /// meant for one never answers the next.
    public let id: Int
    public let tab: Int
    public let kind: LeoBrowserDialogKind
    /// The page's own text, as given: untrusted.
    public let message: String
    /// A prompt's default text; nil for the other kinds.
    public let defaultText: String?
    /// The site of the frame that opened it, in local terms.
    public let site: LeoBrowserSite

    public init(id: Int, tab: Int, kind: LeoBrowserDialogKind, message: String, defaultText: String?, site: LeoBrowserSite) {
        self.id = id
        self.tab = tab
        self.kind = kind
        self.message = message
        self.defaultText = defaultText
        self.site = site
    }
}

/// Who answered a dialog.
public enum LeoBrowserDialogAnswerer: String, Sendable {
    case user, agent
}

/// What the page hears back.
public struct LeoBrowserDialogReply: Equatable, Sendable {
    /// OK, or Leave Page; an alert is always accepted.
    public let accepted: Bool
    /// What `prompt()` returns: the text when accepted, nil when dismissed.
    /// nil for every other kind.
    public let text: String?

    public init(accepted: Bool, text: String?) {
        self.accepted = accepted
        self.text = text
    }
}

/// How a dialog was answered, and by whom.
public struct LeoBrowserDialogAnswer: Equatable, Sendable {
    public let dialog: LeoBrowserDialog
    public let answerer: LeoBrowserDialogAnswerer
    /// OK (an alert's only button) or Leave Page; false for Cancel or Stay on Page.
    public let accepted: Bool

    public init(dialog: LeoBrowserDialog, answerer: LeoBrowserDialogAnswerer, accepted: Bool) {
        self.dialog = dialog
        self.answerer = answerer
        self.accepted = accepted
    }
}

/// An agent browser's JavaScript dialogs (B-412): at most one per tab,
/// each waiting on whoever answers first, the user in the pane or the agent
/// with `browser_dialog`. The page hears back exactly once, however the
/// dialog ends; a withdrawn dialog is dismissed. Nothing here answers a
/// dialog on its own: one on a hidden tab waits until someone does.
@MainActor
public final class LeoBrowserDialogDesk {
    /// Hands the reply to the page. Called exactly once per dialog.
    public typealias Resolver = @MainActor (LeoBrowserDialogReply) -> Void

    public enum Event: Equatable, Sendable {
        case opened(LeoBrowserDialog)
        case answered(LeoBrowserDialogAnswer)
        /// Dismissed because nobody may answer it any more (its tab closed,
        /// its page stopped or went away).
        case withdrawn(LeoBrowserDialog)
    }

    public enum AnswerResult: Equatable, Sendable {
        case answered(LeoBrowserDialogAnswer)
        /// The other side answered first; this is how.
        case alreadyHandled(LeoBrowserDialogAnswer)
        case noDialog
    }

    /// The most user answers kept for the agent before the oldest is dropped.
    static let noteLimit = 10

    private struct Waiting {
        let dialog: LeoBrowserDialog
        let resolve: Resolver
    }

    private var waiting: [Int: Waiting] = [:]
    /// Each tab's last answered dialog, until the tab's next dialog is withdrawn.
    private var lastAnswers: [Int: LeoBrowserDialogAnswer] = [:]
    /// Dialogs the agent has been shown, so the user's answer is worth telling it.
    private var told: Set<Int> = []
    private var notes: [LeoBrowserDialogAnswer] = []
    private var observers: [UUID: @MainActor (Event) -> Void] = [:]
    private var nextID = 1

    public init() {}

    /// Every open dialog, by tab.
    public var dialogs: [LeoBrowserDialog] { waiting.values.map(\.dialog).sorted { $0.tab < $1.tab } }

    public func dialog(inTab tab: Int) -> LeoBrowserDialog? { waiting[tab]?.dialog }

    /// A page opened a dialog. nil, with the new one dismissed at once,
    /// when `tab` already has one open: a page is paused while its dialog
    /// is up, so a second can only come from elsewhere in the same tab.
    @discardableResult
    public func open(
        tab: Int, kind: LeoBrowserDialogKind, message: String, defaultText: String?, site: LeoBrowserSite,
        resolve: @escaping Resolver
    ) -> LeoBrowserDialog? {
        guard waiting[tab] == nil else {
            resolve(LeoBrowserDialogReply(accepted: kind == .alert, text: nil))
            return nil
        }
        let dialog = LeoBrowserDialog(
            id: nextID, tab: tab, kind: kind, message: message, defaultText: kind == .prompt ? defaultText : nil, site: site
        )
        nextID += 1
        waiting[tab] = Waiting(dialog: dialog, resolve: resolve)
        emit(.opened(dialog))
        return dialog
    }

    /// Answers `tab`'s open dialog, or, given `dialog`, only that one.
    /// `text` is a prompt's answer when accepting it; without it the
    /// prompt's default goes back. When the dialog was already answered,
    /// says how; telling the agent that way uses up its note.
    public func answer(
        inTab tab: Int, dialog id: Int? = nil, accept: Bool, text: String? = nil, by answerer: LeoBrowserDialogAnswerer
    ) -> AnswerResult {
        guard let open = waiting[tab], id == nil || open.dialog.id == id else {
            guard let last = lastAnswers[tab], id == nil || last.dialog.id == id else { return .noDialog }
            if answerer == .agent { notes.removeAll { $0.dialog.id == last.dialog.id } }
            return .alreadyHandled(last)
        }
        let dialog = open.dialog
        let reply = Self.reply(to: dialog, accept: accept, text: text)
        let answer = LeoBrowserDialogAnswer(dialog: dialog, answerer: answerer, accepted: reply.accepted)
        waiting[tab] = nil
        lastAnswers[tab] = answer
        if told.remove(dialog.id) != nil, answerer == .user {
            notes = Array((notes + [answer]).suffix(Self.noteLimit))
        }
        open.resolve(reply)
        emit(.answered(answer))
        return .answered(answer)
    }

    /// Dismisses `tab`'s open dialog: nobody may answer it any more. False
    /// when it had none.
    @discardableResult
    public func withdraw(inTab tab: Int) -> Bool {
        lastAnswers[tab] = nil
        guard let open = waiting.removeValue(forKey: tab) else { return false }
        told.remove(open.dialog.id)
        open.resolve(Self.reply(to: open.dialog, accept: false, text: nil))
        emit(.withdrawn(open.dialog))
        return true
    }

    /// Dismisses every open dialog (the browser is going away).
    public func withdrawAll() {
        waiting.keys.sorted().forEach { withdraw(inTab: $0) }
    }

    /// The agent has been shown `id`: if the user answers it, the agent hears.
    public func markTold(_ id: Int) {
        guard waiting.values.contains(where: { $0.dialog.id == id }) else { return }
        told.insert(id)
    }

    /// Whether the agent has been shown open dialog `id`.
    public func wasTold(_ id: Int) -> Bool { told.contains(id) }

    /// The user's answers to dialogs the agent was shown, oldest first,
    /// each given once.
    public func takeNotes() -> [LeoBrowserDialogAnswer] {
        defer { notes = [] }
        return notes
    }

    /// Calls `handler` after every change until the returned closure is called.
    public func observe(_ handler: @escaping @MainActor (Event) -> Void) -> @MainActor () -> Void {
        let id = UUID()
        observers[id] = handler
        return { [weak self] in self?.observers[id] = nil }
    }

    private func emit(_ event: Event) {
        observers.values.forEach { $0(event) }
    }

    private static func reply(to dialog: LeoBrowserDialog, accept: Bool, text: String?) -> LeoBrowserDialogReply {
        switch dialog.kind {
        case .alert: LeoBrowserDialogReply(accepted: true, text: nil)
        case .confirm, .leave: LeoBrowserDialogReply(accepted: accept, text: nil)
        case .prompt: LeoBrowserDialogReply(accepted: accept, text: accept ? text ?? dialog.defaultText ?? "" : nil)
        }
    }
}
