import LeoKit
import SwiftUI

/// The Tasks pane on the generic collection view: each row carries its enabled
/// switch and a Run Now button, the detail adds Prompt and History pages beside
/// the schema form, and Add asks for a schedule as well as a name.
struct LeoTasksView: View {
    @ObservedObject var model: LeoTasksSettingsModel
    let machine: String

    var body: some View {
        LeoConfigCollectionView(model: model.collection, machine: machine, extras: extras)
    }

    private var extras: LeoConfigCollectionExtras {
        LeoConfigCollectionExtras(
            row: { item in AnyView(LeoTaskRow(model: model, item: item)) },
            listFooter: AnyView(LeoTaskRunNoticeView(notice: model.runNotice)),
            detail: { form in AnyView(LeoTaskDetail(model: model, form: form)) },
            addSheet: { submit, cancel in AnyView(LeoTaskAddSheet(model: model, submit: submit, cancel: cancel)) },
            cronPreviews: model.schedulePreview.map { ["schedule": $0] } ?? [:]
        )
    }
}

/// A task's list row: name and schedule, the enabled switch, Run Now.
private struct LeoTaskRow: View {
    @ObservedObject var model: LeoTasksSettingsModel
    let item: LeoConfigItem

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                if let schedule = item.values["schedule"]?.stringValue, !schedule.isEmpty {
                    Text(schedule).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button { Task { await model.runNow(item.name) } } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .help("Run Now: starts \(item.name) with its saved settings")
                .accessibilityLabel("Run \(item.name) now")
            Toggle("Enabled", isOn: Binding(
                get: { model.isEnabled(item) }, set: { enabled in Task { await model.setEnabled(enabled, for: item.name) } }
            ))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            .help(model.isEnabled(item) ? "Enabled: runs on its schedule" : "Disabled")
            .accessibilityLabel("\(item.name) enabled")
        }
    }
}

/// What Run Now last said.
struct LeoTaskRunNoticeView: View {
    let notice: LeoTaskRunNotice?

    var body: some View {
        switch notice {
        case .starting(let name)?:
            Label("Starting \(name)…", systemImage: "play.circle").font(.caption).foregroundStyle(.secondary)
        case .started(let name)?:
            Label("Started \(name)", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed(let name, let reason)?:
            Label("Couldn’t start \(name): \(reason)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }
}

/// The selected task: a page switch over the schema form, the prompt editor
/// and the run history.
private struct LeoTaskDetail: View {
    @ObservedObject var model: LeoTasksSettingsModel
    let form: AnyView

    var body: some View {
        VStack(spacing: 0) {
            Picker("Page", selection: Binding(get: { model.page }, set: { model.setPage($0) })) {
                ForEach(LeoTasksSettingsModel.Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top], 12).padding(.bottom, 8)
            .accessibilityLabel("Task page")
            if let message = model.message {
                LeoTaskMessageBanner(message: message, dismiss: model.dismissMessage).padding([.horizontal, .bottom], 12)
            }
            switch model.page {
            case .settings: form
            case .prompt: LeoTaskPromptEditor(model: model)
            case .history: LeoTaskHistoryView(model: model)
            }
        }
    }
}

struct LeoTaskMessageBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red).accessibilityHidden(true)
            Text(message).textSelection(.enabled)
            Spacer(minLength: 12)
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
