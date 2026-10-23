import LeoKit
import SwiftUI

/// Asks for a new task's name and its schedule (the one field the daemon
/// requires to add a task), reading the schedule back as it is typed.
struct LeoTaskAddSheet: View {
    @ObservedObject var model: LeoTasksSettingsModel
    let submit: (_ name: String, _ values: [String: LeoConfigValue]) -> Void
    let cancel: () -> Void

    @State private var name = ""
    @State private var schedule = ""
    @State private var preview: LeoCronPreviewResult?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New task").font(.headline)
            Form {
                TextField("Name", text: $name).focused($isFocused).onSubmit(confirm)
                LabeledContent("Schedule") {
                    LeoCronField(text: $schedule, preview: preview, prompt: Text("0 3 * * *"))
                }
            }
            .formStyle(.columns)
            Text(nameError ?? " ").font(.caption).foregroundStyle(.red).accessibilityHidden(nameError == nil)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Add", action: confirm).keyboardShortcut(.defaultAction).disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        .onAppear { isFocused = true }
        .task(id: schedule) {
            preview = nil
            preview = await model.previewNewSchedule(schedule)
        }
    }

    private var nameError: String? {
        name.isEmpty ? nil : model.collection.nameError(name)
    }

    private var canAdd: Bool {
        guard !name.isEmpty, nameError == nil, !schedule.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if case .invalid? = preview { return false }
        return true
    }

    private func confirm() {
        guard canAdd else { return }
        submit(name, ["schedule": .string(schedule.trimmingCharacters(in: .whitespaces))])
    }
}
