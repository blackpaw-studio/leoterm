import LeoKit
import SwiftUI

/// What a resource adds to the generic collection pane. Every part is
/// optional; an empty value is the plain list and form.
struct LeoConfigCollectionExtras {
    /// Content after an item's name in the list.
    var row: ((LeoConfigItem) -> AnyView)?
    /// Content under the list's buttons.
    var listFooter: AnyView?
    /// Wraps the standard detail (banners, form, Save bar), which it is handed.
    var detail: ((AnyView) -> AnyView)?
    /// Replaces the add sheet. `submit` takes the name and the extra fields to send with it.
    var addSheet: ((_ submit: @escaping (String, [String: LeoConfigValue]) -> Void, _ cancel: @escaping () -> Void) -> AnyView)?
    /// A live description under a cron field, by its path.
    var cronPreviews: [String: LeoCronPreviewResult] = [:]
}

/// A collection resource's pane: the item list with add / remove / more, and
/// the selected item's schema form under a Save / Revert bar.
struct LeoConfigCollectionView: View {
    @ObservedObject var model: LeoConfigCollectionModel
    let machine: String
    var restart = LeoConfigRestartActions.none
    var extras = LeoConfigCollectionExtras()

    @State private var nameRequest: NameRequest?

    private enum NameRequest: Identifiable {
        case add, rename, duplicate
        var id: Self { self }
    }

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            LeoPaneFailure(message: message) { Task { await model.load() } }
        case .loaded:
            HSplitView {
                list.frame(minWidth: 170, idealWidth: 200, maxWidth: 280)
                detail.frame(minWidth: 380, maxWidth: .infinity)
            }
            .sheet(item: $nameRequest, content: nameSheet)
            .alert(confirmationTitle, isPresented: confirmationBinding, presenting: model.confirmation, actions: confirmationButtons) { _ in
                Text(confirmationMessage)
            }
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                ForEach(model.items) { item in
                    row(item).tag(item.name).accessibilityIdentifier("leo.config.item.\(item.name)")
                }
            }
            .accessibilityLabel(model.title)
            Divider()
            HStack(spacing: 2) {
                if model.actions.contains(.add) {
                    Button { nameRequest = .add } label: { Image(systemName: "plus") }
                        .help("Add").accessibilityLabel("Add").disabled(!model.canRestructure)
                }
                if model.actions.contains(.delete) {
                    Button { model.requestDelete() } label: { Image(systemName: "minus") }
                        .help("Delete").accessibilityLabel("Delete").disabled(!model.canRestructure || model.selection == nil)
                }
                if model.actions.contains(.rename) || model.actions.contains(.duplicate) {
                    moreMenu
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
            if let footer = extras.listFooter {
                footer.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder private func row(_ item: LeoConfigItem) -> some View {
        if let accessory = extras.row {
            accessory(item)
        } else {
            Text(item.name)
        }
    }

    private var moreMenu: some View {
        Menu {
            if model.actions.contains(.rename) { Button("Rename…") { nameRequest = .rename } }
            if model.actions.contains(.duplicate) { Button("Duplicate…") { nameRequest = .duplicate } }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(model.isDirty ? "Save or revert your edits first" : "More")
        .accessibilityLabel("More actions")
        .disabled(!model.canRestructure || model.selection == nil)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if model.draft == nil {
            Text("No \(model.title.lowercased()) yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let wrap = extras.detail {
            wrap(AnyView(standardDetail))
        } else {
            standardDetail
        }
    }

    private var standardDetail: some View {
        VStack(spacing: 0) {
            banners
            LeoSchemaForm(
                sections: model.sections, formErrors: model.draft?.formErrors ?? [], cronPreviews: extras.cronPreviews,
                set: { model.set($0, $1) }, revert: { model.revert($0) }
            )
            Divider()
            saveBar
        }
    }

    @ViewBuilder private var banners: some View {
        let hasBanner = model.conflict != nil || model.errorMessage != nil || model.warning != nil || model.restartPrompt != nil
        if hasBanner {
            VStack(spacing: 8) {
                if model.conflict != nil { conflictBanner }
                if let message = model.errorMessage { messageBanner(message, symbol: "exclamationmark.octagon.fill", tint: .red) }
                if let warning = model.warning { messageBanner(warning, symbol: "exclamationmark.triangle.fill", tint: .orange) }
                if let required = model.restartPrompt {
                    LeoRestartPrompt(required: required, machine: machine, actions: restart, dismiss: model.dismissRestartPrompt)
                }
            }
            .padding(12)
        }
    }

    private var conflictBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Changed on \(machine) since you opened it").font(.headline)
                Text("Reload keeps your edits over the new settings. Overwrite replaces what changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Reload") { Task { await model.reloadAfterConflict() } }
            Button("Overwrite", role: .destructive) { Task { await model.overwrite() } }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private func messageBanner(_ message: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(message).textSelection(.enabled)
            Spacer(minLength: 12)
            Button("Dismiss", action: model.dismissError).buttonStyle(.borderless)
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var saveBar: some View {
        HStack {
            if model.isBusy { ProgressView().controlSize(.small) }
            Spacer()
            Button("Revert") { model.revertAll() }.disabled(!model.isDirty || model.isBusy)
            Button("Save") { Task { await model.save() } }
                .keyboardShortcut(.defaultAction).disabled(!model.canSave)
        }
        .padding(12)
    }

    // MARK: Sheets and alerts

    @ViewBuilder private func nameSheet(_ request: NameRequest) -> some View {
        switch request {
        case .add where extras.addSheet != nil:
            extras.addSheet?(
                { name, values in nameRequest = nil; Task { await model.add(name: name, values: values) } }, { nameRequest = nil }
            )
        case .add:
            LeoNameSheet(
                title: "New \(singular)", confirmTitle: "Add", name: "", validate: { model.nameError($0) },
                submit: { name in nameRequest = nil; Task { await model.add(name: name) } }, cancel: { nameRequest = nil }
            )
        case .rename:
            LeoNameSheet(
                title: "Rename “\(model.selection ?? "")”", confirmTitle: "Rename", name: model.selection ?? "",
                validate: { model.nameError($0, excluding: model.selection) },
                submit: { name in nameRequest = nil; Task { await model.rename(to: name) } }, cancel: { nameRequest = nil }
            )
        case .duplicate:
            LeoNameSheet(
                title: "Duplicate “\(model.selection ?? "")”", confirmTitle: "Duplicate", name: "\(model.selection ?? "") copy",
                validate: { model.nameError($0) },
                submit: { name in nameRequest = nil; Task { await model.duplicate(as: name) } }, cancel: { nameRequest = nil }
            )
        }
    }

    private var singular: String {
        let title = model.title
        return title.hasSuffix("s") ? String(title.dropLast()).lowercased() : title.lowercased()
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { model.confirmation != nil }, set: { if !$0 { model.cancelConfirmation() } })
    }

    private var confirmationTitle: String {
        switch model.confirmation {
        case .delete(let name)?: "Delete \(singular) “\(name)”?"
        case .discardChanges?, nil: "Discard unsaved changes?"
        }
    }

    private var confirmationMessage: String {
        switch model.confirmation {
        case .delete?: "It is removed from leo.yaml on \(machine). Anything that still refers to it will need another \(singular)."
        case .discardChanges?, nil: "Your edits haven't been saved to \(machine)."
        }
    }

    @ViewBuilder private func confirmationButtons(_ confirmation: LeoConfigCollectionModel.Confirmation) -> some View {
        switch confirmation {
        case .delete: Button("Delete", role: .destructive) { Task { await model.confirm(confirmation) } }
        case .discardChanges: Button("Discard", role: .destructive) { Task { await model.confirm(confirmation) } }
        }
        Button("Cancel", role: .cancel) {}
    }
}

/// A pane that couldn't load: the reason and a retry.
struct LeoPaneFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Couldn’t load these settings").font(.headline)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            Button("Try Again", action: retry)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
