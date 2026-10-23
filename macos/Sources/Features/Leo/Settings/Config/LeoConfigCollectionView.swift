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
    /// What deleting an item also means, when more than removing it, added to the confirmation.
    var deleteNote: ((String) -> String?)?
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

    private var banners: some View {
        LeoConfigBanners(
            machine: machine, hasConflict: model.conflict != nil, errorMessage: model.errorMessage, warning: model.warning,
            restartPrompt: model.restartPrompt, restart: restart,
            reload: { Task { await model.reloadAfterConflict() } }, overwrite: { Task { await model.overwrite() } },
            dismissError: model.dismissError, dismissRestart: model.dismissRestartPrompt
        )
    }

    private var saveBar: some View {
        LeoConfigSaveBar(
            isBusy: model.isBusy, isDirty: model.isDirty, canSave: model.canSave,
            revert: { model.revertAll() }, save: { Task { await model.save() } }
        )
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
        case .delete(let name)?:
            (["It is removed from leo.yaml on \(machine). Anything that still refers to it will need another \(singular)."]
                + [extras.deleteNote?(name)].compactMap { $0 }).joined(separator: " ")
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
