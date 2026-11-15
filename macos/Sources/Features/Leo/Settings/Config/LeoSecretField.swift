import LeoKit
import SwiftUI

/// A write-only value: the daemon never sends it back, so the field says
/// whether one is set and offers Replace… and Clear. A pending change shows
/// until Save and can be undone.
struct LeoSecretField: View {
    let state: LeoConfigSecretState
    /// When set, Clear asks first and names this.
    var confirmClearOf: String?
    let set: (LeoConfigValue) -> Void
    let revert: () -> Void

    @State private var isReplacing = false
    @State private var isConfirmingClear = false
    @State private var replacement = ""

    var body: some View {
        HStack(spacing: 8) {
            if isReplacing {
                SecureField("New value", text: $replacement).labelsHidden().frame(maxWidth: 200)
                Button("Replace") { commit() }.disabled(replacement.isEmpty)
                Button("Cancel") { isReplacing = false; replacement = "" }
            } else {
                Text(summary).foregroundStyle(summaryStyle)
                switch state {
                case .set:
                    Button("Replace…") { isReplacing = true }
                    Button("Clear") { confirmClearOf == nil ? set(.secretClear) : (isConfirmingClear = true) }
                case .notSet:
                    Button("Set…") { isReplacing = true }
                case .replacing, .clearing:
                    Button("Undo") { revert() }
                }
            }
        }
        .confirmationDialog(clearTitle, isPresented: $isConfirmingClear) {
            Button("Clear", role: .destructive) { set(.secretClear) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is removed when you save. You can undo it until then.")
        }
    }

    private var clearTitle: String { "Clear \(confirmClearOf ?? "this value")?" }

    private var summary: String {
        switch state {
        case .set: "Set"
        case .notSet: "Not set"
        case .replacing: "Will be replaced"
        case .clearing: "Will be cleared"
        }
    }

    private var summaryStyle: HierarchicalShapeStyle {
        switch state {
        case .set, .notSet: .secondary
        case .replacing, .clearing: .primary
        }
    }

    private func commit() {
        set(.secretReplace(replacement))
        replacement = ""
        isReplacing = false
    }
}
