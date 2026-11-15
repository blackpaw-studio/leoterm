import Foundation

/// A read that may still be on its way.
public enum LeoTasksLoad<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}

/// What Run Now last said, for the task it was pressed on.
public enum LeoTaskRunNotice: Equatable, Sendable {
    case starting(String)
    case started(String)
    case failed(String, String)

    public var task: String {
        switch self {
        case .starting(let name), .started(let name), .failed(let name, _): name
        }
    }
}

/// The selected task's prompt file editor: the file the daemon serves, the
/// text being edited, and what is in the way of saving it. The decisions
/// below are the rules both platforms follow, so a prompt never lands in a
/// file the task no longer uses.
public struct LeoTaskPromptState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded
        /// The daemon won't serve the configured file (a protected path).
        case unavailable(String)
        case failed(String)
    }

    public enum Confirmation: Equatable, Sendable {
        /// Switch files, dropping the unsaved text.
        case switchFile(String)
        /// The task now uses this file; the text was typed for the one it left.
        case fileChanged(String)
        /// The form's Save would point the task at this file.
        case saveWithFile(String)
    }

    /// Whether the prompt may be written to the file it was read from.
    public enum SaveCheck: Equatable, Sendable {
        case proceed
        case askFileChanged
    }

    /// What the task's list changing means for an open prompt.
    public enum ItemsChange: Equatable, Sendable {
        case none
        /// The task follows another file and the prompt has no edits: read it again.
        case reload
    }

    public var phase: Phase
    /// The `prompt_file` this state was read for.
    public var file: String?
    public var document: LeoTaskPrompt?
    public var text: String
    /// The prompt file's current revision when it moved on since this was read.
    public var conflict: String?
    public var error: String?
    public var isSaving: Bool
    public var confirmation: Confirmation?

    public init(
        phase: Phase = .idle, file: String? = nil, document: LeoTaskPrompt? = nil, text: String = "", conflict: String? = nil,
        error: String? = nil, isSaving: Bool = false, confirmation: Confirmation? = nil
    ) {
        self.phase = phase
        self.file = file
        self.document = document
        self.text = text
        self.conflict = conflict
        self.error = error
        self.isSaving = isSaving
        self.confirmation = confirmation
    }

    public var isDirty: Bool {
        phase == .loaded && document.map { $0.content != text } == true
    }

    /// There is text to write and nothing already writing it.
    public var canWrite: Bool {
        phase == .loaded && isDirty && !isSaving && document != nil
    }

    /// Before a save: the file the task is configured with must still be the
    /// one the text was read from, else the user is asked first.
    public mutating func saveCheck(configuredFile: String) -> SaveCheck {
        guard configuredFile != document?.file else { return .proceed }
        confirmation = .fileChanged(configuredFile)
        return .askFileChanged
    }

    /// A 409 on the prompt. `served` is the file the daemon serves now: if the
    /// task moved to another one the text is for the wrong file, so the user
    /// is asked; otherwise the file changed underneath and it is a conflict.
    public mutating func conflictOutcome(served: LeoTaskPrompt?, current: String) {
        if let served, served.file != document?.file {
            confirmation = .fileChanged(served.file)
        } else {
            conflict = current
        }
    }

    /// The task's configured `prompt_file` after its list changed. A prompt
    /// with no edits follows the new file; one with edits stays, with the
    /// choice put to the user: that text was typed for the old one.
    public mutating func itemsChanged(configuredFile: String) -> ItemsChange {
        guard phase != .idle else { return .none }
        guard !isDirty else {
            if configuredFile != document?.file {
                confirmation = .fileChanged(configuredFile)
            } else if case .fileChanged? = confirmation {
                confirmation = nil
            }
            return .none
        }
        return configuredFile != file ? .reload : .none
    }

    /// The form's Save that would repoint the task drops the prompt text, so
    /// it asks first: false holds the save.
    public mutating func formSaveAllowed(patch: [String: LeoConfigValue]) -> Bool {
        guard isDirty, let change = patch["prompt_file"] else { return true }
        let file = change.stringValue ?? ""
        guard file != document?.file else { return true }
        confirmation = .saveWithFile(file)
        return false
    }

    /// The daemon took `sent` for `saved.file`.
    public mutating func saved(_ saved: LeoTaskPromptWrite, sent: String) {
        guard let document else { return }
        let files = Set(document.files + [saved.file]).sorted()
        self.document = LeoTaskPrompt(revision: saved.revision, file: saved.file, files: files, content: sent)
        conflict = nil
    }

    /// Drops the unsaved text (the editor's Revert).
    public mutating func discardEdits() {
        text = document?.content ?? ""
        conflict = nil
        error = nil
        confirmation = nil
    }
}

/// The task list's enabled switches, shown at once while their writes are
/// still queued. An override stays until the last write for that task lands.
public struct LeoTaskToggleOverrides: Equatable, Sendable {
    private var enabled: [String: Bool] = [:]
    private var pending: [String: Int] = [:]

    public init() {}

    public func isEnabled(_ item: LeoConfigItem) -> Bool {
        enabled[item.name] ?? item.values["enabled"]?.boolValue ?? false
    }

    /// The switch was flipped: show it now and count the write.
    public mutating func begin(_ name: String, enabled value: Bool) {
        enabled[name] = value
        pending[name, default: 0] += 1
    }

    /// One write for `name` finished, whether it worked or not: the list read
    /// back (or the rollback) is what the switch shows once none are left.
    public mutating func finish(_ name: String) {
        pending[name, default: 0] -= 1
        guard pending[name, default: 0] <= 0 else { return }
        pending[name] = nil
        enabled[name] = nil
    }
}

extension LeoTaskLog {
    /// The most of a log the app shows. The daemon already caps what it
    /// sends at 4 MiB; a phone shows the end of that.
    public static let displayLimit = 256 * 1024

    /// The last `maxBytes` of the text, cut to start on a line. The result is
    /// marked truncated when anything was dropped. A last line longer than the
    /// limit keeps its end, on a character boundary.
    public func tail(maxBytes: Int = LeoTaskLog.displayLimit) -> LeoTaskLog {
        let bytes = Array(text.utf8)
        guard bytes.count > maxBytes else { return self }
        guard maxBytes > 0 else { return LeoTaskLog(file: file, text: "", truncated: true) }
        var start = bytes.count - maxBytes
        if bytes[start - 1] != Self.newline {
            if let newline = bytes[start...].firstIndex(of: Self.newline), newline + 1 < bytes.count {
                start = newline + 1
            } else {
                while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
            }
        }
        return LeoTaskLog(file: file, text: String(bytes: bytes[start...], encoding: .utf8) ?? "", truncated: true)
    }

    private static let newline = UInt8(ascii: "\n")
}
