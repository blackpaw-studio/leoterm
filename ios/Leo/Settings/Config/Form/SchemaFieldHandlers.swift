import LeoKit
import UIKit

/// What a schema cell asks of whoever shows it. Every edit leaves a cell as
/// `(path, value)` through `edit`; the owner decides what a path means.
@MainActor
struct SchemaFieldHandlers {
    var edit: (_ path: String, _ value: LeoConfigValue) -> Void = { _, _ in }
    /// Undo this field's pending change.
    var revert: (_ path: String) -> Void = { _ in }
    var push: (SchemaFieldEditor) -> Void = { _ in }
    /// Asks for a secret's new value, calling back with it, or nil on cancel.
    var promptSecret: (_ title: String, _ done: @escaping (String?) -> Void) -> Void = { _, done in done(nil) }
    var open: (URL) -> Void = { UIApplication.shared.open($0) }
}

/// A field whose value is edited on a screen of its own.
enum SchemaFieldEditor: Equatable {
    case text(LeoConfigFormRow)
    case list(LeoConfigFormRow)
    case keyValue(LeoConfigFormRow)

    var row: LeoConfigFormRow {
        switch self {
        case .text(let row), .list(let row), .keyValue(let row): row
        }
    }

    var isMonospaced: Bool { row.control == .yaml }
}
