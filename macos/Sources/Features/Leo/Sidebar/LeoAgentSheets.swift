import SwiftUI
import LeoKit

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

/// Copy and Duplicate: asks for the copy's optional name, then starts the
/// copy on `destination`, or on the agent's own host when it is nil.
struct LeoCopyAgentSheet: View {
    let row: LeoAgentRow
    let destination: String?
    @ObservedObject var actions: LeoAgentActions
    /// Closes the sheet where SwiftUI's `dismiss` can't: a sheet presented
    /// by `NSWindow.presentLeoSheet` has no presenting controller to ask.
    var close: () -> Void = {}
    @State private var name = ""

    private var validation: String? { SpawnValidation.name(name, current: row.name) }
    private var title: String { destination.map { "Copy \(row.name) to \($0)" } ?? "Duplicate \(row.name)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $name, prompt: Text("\(row.name)-copy"))
            if let validation {
                Text(validation).foregroundStyle(Color(nsColor: .systemRed))
            }
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Copy") {
                    let chosen = name.isEmpty ? nil : name
                    if let destination {
                        actions.copy(row, to: destination, name: chosen)
                    } else {
                        actions.duplicate(row, name: chosen)
                    }
                    close()
                }.keyboardShortcut(.defaultAction).disabled(validation != nil)
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

/// The start sheet's presentation item: equal by id alone, so the sheet
/// stays up (and its `onDisappear` doesn't fire) when its prompt moves
/// from asking to waiting.
struct LeoStartPromptSheetItem: Identifiable, Equatable {
    let prompt: LeoStartPrompt
    var id: LeoStartPrompt.ID { prompt.id }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// B-049: asked when a click would go to an agent that isn't running. Start
/// starts it through the daemon; the sheet then waits, cancellably, until
/// the daemon reports it running and the model attaches it. Reads the
/// prompt's current phase from the model, so the same sheet moves from
/// asking to waiting.
struct LeoStartAgentSheet: View {
    @ObservedObject var model: LeoSidebarModel
    let prompt: LeoStartPrompt

    private var current: LeoStartPrompt {
        model.startPrompt(in: prompt.origin).flatMap { $0.id == prompt.id ? $0 : nil } ?? prompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch current.phase {
            case .confirm:
                Text("Start \(prompt.agent.name)?").font(.headline)
                Text("It opens here once it\u{2019}s running.").foregroundStyle(.secondary)
            case .waiting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting \(prompt.agent.name)\u{2026}").font(.headline)
                }
                Text("It opens here once it\u{2019}s running.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelStartPrompt(prompt.id) }
                    .keyboardShortcut(.cancelAction)
                if current.phase == .confirm {
                    Button("Start") { model.confirmStart(prompt.id) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding().frame(width: 360)
        // Closing the window (or anything else that takes the sheet away)
        // ends the wait: nothing attaches into a window that's gone.
        .onDisappear { model.cancelStartPrompt(prompt.id) }
    }
}
