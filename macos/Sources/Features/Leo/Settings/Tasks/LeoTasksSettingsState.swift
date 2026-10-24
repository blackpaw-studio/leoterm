import LeoKit

/// A read that may still be on its way.
enum LeoTasksLoad<Value: Equatable>: Equatable {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}

/// What Run Now last said, for the task it was pressed on.
enum LeoTaskRunNotice: Equatable {
    case starting(String)
    case started(String)
    case failed(String, String)

    var task: String {
        switch self {
        case .starting(let name), .started(let name), .failed(let name, _): name
        }
    }
}

/// The selected task's prompt file editor: the file the daemon serves, the
/// text being edited, and what is in the way of saving it.
struct LeoTaskPromptState: Equatable {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        /// The daemon won't serve the configured file (a protected path).
        case unavailable(String)
        case failed(String)
    }

    enum Confirmation: Equatable {
        /// Switch files, dropping the unsaved text.
        case switchFile(String)
        /// The task now uses this file; the text was typed for the one it left.
        case fileChanged(String)
        /// The form's Save would point the task at this file.
        case saveWithFile(String)
    }

    var phase = Phase.idle
    /// The `prompt_file` this state was read for.
    var file: String?
    var document: LeoTaskPrompt?
    var text = ""
    /// The prompt file's current revision when it moved on since this was read.
    var conflict: String?
    var error: String?
    var isSaving = false
    var confirmation: Confirmation?

    var isDirty: Bool {
        phase == .loaded && document.map { $0.content != text } == true
    }
}
