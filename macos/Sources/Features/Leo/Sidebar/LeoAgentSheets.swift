import SwiftUI

/// Rename sheet shared by the sidebar row's context menu and the menu-bar
/// "Agents" menu -- both act on the same `LeoAgentActions.rename`, so a
/// single implementation guarantees they can never disagree.
struct LeoRenameAgentSheet: View {
    let row: LeoAgentRow
    @ObservedObject var actions: LeoAgentActions
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(row: LeoAgentRow, actions: LeoAgentActions) {
        self.row = row
        self.actions = actions
        _name = State(initialValue: row.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(row.name)").font(.headline)
            TextField("Name", text: $name)
            if let validation = SpawnValidation.rename(name, current: row.name) {
                Text(validation).foregroundStyle(Color(nsColor: .systemRed))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename") {
                    actions.rename(row, newName: name)
                    dismiss()
                }.disabled(SpawnValidation.rename(name, current: row.name) != nil)
            }
        }.padding().frame(width: 360)
    }
}

/// Delete sheet shared the same way. `error`/`errorCode` are passed in
/// rather than read from a model directly, so this view stays agnostic
/// about where they come from: a caller embedded in a reactive SwiftUI tree
/// (the sidebar row) can pass its own already-observed props, while a
/// caller presenting a standalone `NSHostingController` sheet (the menu
/// bar) can wrap this in a thin container that observes its model and
/// re-supplies fresh values on every change.
struct LeoDeleteAgentSheet: View {
    let row: LeoAgentRow
    @ObservedObject var actions: LeoAgentActions
    let error: String?
    let errorCode: String?
    @Environment(\.dismiss) private var dismiss
    @State private var deletePlan: LeoDeletePlan?
    @State private var forceDelete = false
    @State private var deleteBranch = false

    private var availability: LeoRowActionAvailability {
        LeoRowActionAvailability(status: row.status, isPending: actions.pendingActions.contains(row.id))
    }

    private var deleteSheetAvailability: LeoDeleteSheetActionAvailability {
        LeoDeleteSheetActionAvailability(row: availability, errorCode: errorCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete \(row.name)?").font(.headline)
            if let deletePlan {
                if let path = deletePlan.worktreePath { Text("Worktree: \(path)") }
                if let branch = deletePlan.branch { Text("Branch: \(branch)") }
                if deletePlan.branch != nil { Toggle("Also delete branch", isOn: $deleteBranch) }
            }
            if let error, LeoDeleteActionState.canStopFirst(errorCode: errorCode) {
                Text(error).foregroundStyle(Color(nsColor: .systemRed))
                Button("Stop first") { actions.stop(row) }.disabled(!deleteSheetAvailability.stopFirst)
            } else if let error {
                Text(error).foregroundStyle(Color(nsColor: .systemRed))
            }
            Toggle("Force", isOn: $forceDelete)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Delete", role: .destructive) {
                    actions.delete(row, force: forceDelete, deleteBranch: deleteBranch) { dismiss() }
                }.disabled(!deleteSheetAvailability.delete)
            }
        }
        .padding().frame(width: 420)
        .task { actions.deletePlan(row) { deletePlan = $0 } }
    }
}
