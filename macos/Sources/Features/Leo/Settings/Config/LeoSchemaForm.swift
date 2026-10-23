import LeoKit
import SwiftUI

/// A resource's detail editor, drawn from the daemon's schema: a grouped
/// `Form` with one section per `LeoConfigFormSection`. It holds no state; the
/// model that owns the draft recomputes `sections` after every `set`.
struct LeoSchemaForm: View {
    let sections: [LeoConfigFormSection]
    /// Messages that belong to no field.
    var formErrors: [String] = []
    /// A live description for a cron field, by its path.
    var cronPreviews: [String: String] = [:]
    let set: (_ path: String, _ value: LeoConfigValue) -> Void
    let revert: (_ path: String) -> Void

    var body: some View {
        Form {
            if !formErrors.isEmpty {
                Section {
                    ForEach(formErrors, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error: \(message)")
                    }
                }
            }
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        LeoSchemaFieldRow(
                            row: row, cronPreview: cronPreviews[row.path],
                            set: { set(row.path, $0) }, revert: { revert(row.path) }
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
