import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// One role in one profile: template (or Not routed), model, effort.
final class DelegationCellEditorViewController: DelegationSheetController {
    static let knownEfforts = ["low", "medium", "high", "xhigh", "max"]

    private let template = UIButton(configuration: .gray())
    private let templateNote = DelegationSheetController.label(style: .caption1)
    private let model = DelegationSheetController.textField(placeholder: "model", id: "delegation.cell.model")
    private let modelNote = DelegationSheetController.label(style: .caption1)
    private let effort = DelegationSheetController.textField(placeholder: "effort", id: "delegation.cell.effort")
    private let effortMenu = UIButton(type: .system)
    private let effortNote = DelegationSheetController.label(style: .caption1)
    private let formError = DelegationSheetController.label(style: .footnote, color: .systemRed)
    private let removal = DelegationSheetController.label(style: .footnote, color: .systemOrange)

    init(store: StoreOf<DelegationSettings>, restart: StoreOf<MachineRestart>?) {
        super.init(store: store, restart: restart, saveTitle: String(localized: "Save"))
    }

    override func build() {
        template.showsMenuAsPrimaryAction = true
        template.configuration?.image = UIImage(systemName: "chevron.up.chevron.down")
        template.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote)
        template.configuration?.imagePlacement = .trailing
        template.configuration?.imagePadding = 6
        template.contentHorizontalAlignment = .leading
        template.accessibilityIdentifier = "delegation.cell.template"
        model.addAction(UIAction { [weak self] _ in self.map { $0.store.send(.cellModelChanged($0.model.text ?? "")) } }, for: .editingChanged)
        effort.addAction(UIAction { [weak self] _ in self.map { $0.store.send(.cellEffortChanged($0.effort.text ?? "")) } }, for: .editingChanged)
        effortMenu.setImage(UIImage(systemName: "chevron.down.circle"), for: .normal)
        effortMenu.showsMenuAsPrimaryAction = true
        effortMenu.accessibilityLabel = String(localized: "Effort choices")
        effortMenu.menu = UIMenu(children: ([""] + Self.knownEfforts).map { value in
            UIAction(title: value.isEmpty ? String(localized: "Default") : value) { [weak self] _ in self?.store.send(.cellEffortChanged(value)) }
        })
        effortMenu.setContentHuggingPriority(.required, for: .horizontal)
        let effortRow = UIStackView(arrangedSubviews: [effort, effortMenu])
        effortRow.spacing = 8
        for view in [Self.caption(String(localized: "Template")), template, templateNote, Self.caption(String(localized: "Model")), model, modelNote,
                     Self.caption(String(localized: "Effort")), effortRow, effortNote, formError, removal] {
            form.addArrangedSubview(view)
        }
        [templateNote, modelNote, effortNote].forEach(gap(after:))
    }

    override func update() {
        guard let editor = store.core.cellEditor else { return }
        let target = editor.edit.target
        let deletes = editor.edit.deletesCell
        title = "\(editor.role) in \(editor.profile)"
        template.configuration?.title = target.template.isEmpty ? String(localized: "Not routed") : target.template
        template.menu = templateMenu(current: target.template)
        let inherited = store.core.templates.first { $0.name == target.template }?.model
        model.placeholder = inherited ?? "model"
        if model.text != target.model { model.text = target.model }
        if effort.text != target.effort { effort.text = target.effort }
        model.isEnabled = !deletes
        effort.isEnabled = !deletes
        effortMenu.isEnabled = !deletes
        show(templateNote, editor.errors["template"], help: nil)
        show(modelNote, editor.errors["model"], help: String(localized: "Empty uses the template’s model."))
        show(effortNote, editor.errors["effort"], help: String(localized: "Empty uses the harness’s default."))
        formError.text = editor.errors[""]
        formError.isHidden = editor.errors[""] == nil
        removal.text = String(localized: "Saving removes this role from \(editor.profile).")
        removal.isHidden = !(deletes && editor.edit.isDirty)
        saveButton.title = deletes ? String(localized: "Remove") : String(localized: "Save")
        saveButton.isEnabled = editor.edit.isDirty && !store.core.isBusy
    }

    /// Every template, plus the cell's own when the machine no longer lists it.
    private func templateMenu(current: String) -> UIMenu {
        let names = store.core.templates.map(\.name)
        let choices = [""] + (current.isEmpty || names.contains(current) ? names : names + [current])
        return UIMenu(children: choices.map { name in
            UIAction(title: name.isEmpty ? String(localized: "Not routed") : name, state: name == current ? .on : .off) { [weak self] _ in
                self?.store.send(.cellTemplateChanged(name))
            }
        })
    }

    private func show(_ label: UILabel, _ error: String?, help: String?) {
        label.text = error ?? help
        label.textColor = error == nil ? .tertiaryLabel : .systemRed
        label.isHidden = label.text == nil
    }

    override func cancel() { store.send(.cellCancelTapped) }
    override func save() { store.send(.cellSaveTapped) }
}

/// What a declared role is for: one write of `use_for`.
final class DelegationUseForViewController: DelegationSheetController, UITextViewDelegate {
    private let text = DelegationSheetController.textView(id: "delegation.useFor.text")
    private let error = DelegationSheetController.label(style: .footnote, color: .systemRed)

    init(store: StoreOf<DelegationSettings>, restart: StoreOf<MachineRestart>?) {
        super.init(store: store, restart: restart, saveTitle: String(localized: "Save"))
    }

    override func build() {
        text.delegate = self
        form.addArrangedSubview(text)
        form.addArrangedSubview(error)
    }

    override func update() {
        guard let editor = store.core.useForEditor else { return }
        title = String(localized: "What \(editor.role) is for")
        if text.text != editor.text { text.text = editor.text }
        error.text = editor.error
        error.isHidden = editor.error == nil
        saveButton.isEnabled = editor.isDirty && !store.core.isBusy
    }

    func textViewDidChange(_ textView: UITextView) { store.send(.useForTextChanged(textView.text)) }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        text.becomeFirstResponder()
    }

    override func cancel() { store.send(.useForCancelTapped) }
    override func save() { store.send(.useForSaveTapped) }
}

/// The Claude Code agent types bridged agents can't spawn while delegation
/// is on, one per line; the whole list is written at once.
final class DelegationHiddenAgentsViewController: DelegationSheetController, UITextViewDelegate {
    private let text = DelegationSheetController.textView(id: "delegation.hiddenAgents.text")
    private let builtIn = DelegationSheetController.label(style: .footnote, color: .secondaryLabel)

    init(store: StoreOf<DelegationSettings>, restart: StoreOf<MachineRestart>?) {
        super.init(store: store, restart: restart, saveTitle: String(localized: "Save"))
        title = String(localized: "Hidden native agents")
    }

    override func build() {
        let about = Self.label(
            String(localized: "While delegation is on, bridged claude agents can’t spawn these Claude Code agent types. One per line; an empty list hides none."),
            style: .footnote, color: .secondaryLabel
        )
        form.addArrangedSubview(about)
        gap(after: about)
        text.delegate = self
        text.text = store.core.hiddenAgentNames.joined(separator: "\n")
        form.addArrangedSubview(text)
        builtIn.text = String(localized: "Using the built-in list. Saving writes it to leo.yaml.")
        form.addArrangedSubview(builtIn)
    }

    override func update() {
        let names = store.core.hiddenAgentNames
        if !text.isFirstResponder, Self.names(in: text.text) != names { text.text = names.joined(separator: "\n") }
        builtIn.isHidden = !store.core.hiddenAgentsAreDefault
        saveButton.isEnabled = store.core.hiddenAgentsEdit?.isDirty == true && !store.core.isBusy
    }

    static func names(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init)
    }

    func textViewDidChange(_ textView: UITextView) { store.send(.hiddenAgentsChanged(Self.names(in: textView.text))) }

    override func cancel() { store.send(.hiddenAgentsCancelTapped) }
    override func save() { store.send(.hiddenAgentsSaveTapped) }
}

/// What making a profile active changes, read before anything is written.
final class DelegationActivateViewController: DelegationSheetController {
    private let headline = DelegationSheetController.label(style: .headline)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let body = DelegationSheetController.label(style: .callout, color: .secondaryLabel)

    init(store: StoreOf<DelegationSettings>, restart: StoreOf<MachineRestart>?) {
        super.init(store: store, restart: restart, saveTitle: String(localized: "Make Active"))
        title = String(localized: "Make Active")
    }

    override func build() {
        spinner.hidesWhenStopped = true
        body.accessibilityIdentifier = "delegation.preview.body"
        [headline, spinner, body].forEach(form.addArrangedSubview)
        gap(after: headline)
    }

    override func update() {
        guard let preview = store.core.preview else { return }
        headline.text = String(localized: "Make “\(preview.profile)” the active profile")
        switch preview {
        case .loading:
            spinner.startAnimating()
            body.text = String(localized: "Checking what changes…")
            body.textColor = .secondaryLabel
            saveButton.isEnabled = false
        case .failed(_, let message):
            spinner.stopAnimating()
            body.text = message
            body.textColor = .systemRed
            saveButton.isEnabled = false
        case .loaded(let loaded):
            spinner.stopAnimating()
            body.text = Self.describe(loaded, active: store.core.document?.activeProfile ?? "")
            body.textColor = .label
            saveButton.isEnabled = !store.core.isBusy
        }
    }

    /// The changes by role, then any declared roles the profile doesn't route.
    static func describe(_ preview: LeoDelegationPreview, active: String) -> String {
        var lines = preview.changes.isEmpty
            ? [String(localized: "Routing is the same as in “\(active)”. Only the active marker moves.")]
            : [String(localized: "Compared with “\(active)”:")] + preview.changes.map { "\($0.role): \(describe($0))" }
        if !preview.missing.isEmpty {
            let missing = preview.missing.joined(separator: ", ")
            lines.append(String(localized: "Not routed by this profile: \(missing). Dispatches for those roles fail until it routes them."))
        }
        return lines.joined(separator: "\n\n")
    }

    private static func describe(_ change: LeoDelegationPreview.Change) -> String {
        switch change.kind {
        case .added: String(localized: "starts routing to \(summary(change.after))")
        case .removed: String(localized: "stops routing (was \(summary(change.before)))")
        case .changed: "\(summary(change.before)) → \(summary(change.after))"
        }
    }

    private static func summary(_ target: LeoDelegationTarget) -> String {
        [target.template, target.model, target.effort].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    override func cancel() { store.send(.activateCancelTapped) }
    override func save() { store.send(.activateConfirmTapped) }
}
