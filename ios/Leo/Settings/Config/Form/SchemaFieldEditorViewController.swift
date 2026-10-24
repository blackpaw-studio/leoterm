import LeoKit
import UIKit

/// The screen a field with a lot to edit (a list, a map, a block of text)
/// opens. The owner feeds it the row again whenever the draft changes, so a
/// revert or a reload shows here too.
@MainActor
protocol SchemaFieldEditorViewController: UIViewController {
    func update(row: LeoConfigFormRow)
}

enum SchemaFieldEditors {
    @MainActor
    static func make(_ editor: SchemaFieldEditor, handlers: SchemaFieldHandlers) -> any SchemaFieldEditorViewController {
        switch editor {
        case .text(let row): TextFieldEditorViewController(row: row, handlers: handlers)
        case .list(let row): StringListEditorViewController(row: row, handlers: handlers)
        case .keyValue(let row): KeyValueEditorViewController(row: row, handlers: handlers)
        }
    }
}

/// A block of text, monospaced for YAML.
final class TextFieldEditorViewController: UIViewController, SchemaFieldEditorViewController, UITextViewDelegate {
    private var row: LeoConfigFormRow
    private let handlers: SchemaFieldHandlers
    private let textView = UITextView()

    init(row: LeoConfigFormRow, handlers: SchemaFieldHandlers) {
        self.row = row
        self.handlers = handlers
        super.init(nibName: nil, bundle: nil)
        title = row.field.label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        textView.accessibilityIdentifier = "field.editor.text"
        textView.delegate = self
        textView.font = row.control == .yaml
            ? .monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular) : .preferredFont(forTextStyle: .body)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.text = row.value.stringValue ?? ""
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    func update(row: LeoConfigFormRow) {
        self.row = row
        let text = row.value.stringValue ?? ""
        if isViewLoaded, textView.text != text { textView.text = text }
    }

    func textViewDidChange(_ textView: UITextView) {
        handlers.edit(row.path, textView.text.isEmpty ? .null : .string(textView.text))
    }
}

/// An ordered list of strings: one field per entry, swipe to delete, and an
/// Add row underneath.
final class StringListEditorViewController: UITableViewController, SchemaFieldEditorViewController {
    private var row: LeoConfigFormRow
    private var items: [String]
    private let handlers: SchemaFieldHandlers

    init(row: LeoConfigFormRow, handlers: SchemaFieldHandlers) {
        self.row = row
        items = row.value.stringList ?? []
        self.handlers = handlers
        super.init(style: .insetGrouped)
        title = row.field.label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(row: LeoConfigFormRow) {
        self.row = row
        let external = row.value.stringList ?? []
        guard isViewLoaded, external != items else { return }
        items = external
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? items.count : 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        if indexPath.section == 1 {
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Add")
            content.image = UIImage(systemName: "plus.circle.fill")
            content.textProperties.color = tableView.tintColor
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "field.editor.add"
            return cell
        }
        let field = UITextField()
        field.accessibilityIdentifier = "field.editor.entry.\(indexPath.row)"
        field.text = items[indexPath.row]
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.addAction(UIAction { [weak self, weak field] _ in
            guard let self, let field, let index = index(of: field) else { return }
            items[index] = field.text ?? ""
            emit()
        }, for: .editingChanged)
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor, constant: 4),
            field.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor, constant: -4),
            field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
        ])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.section == 1 else { return }
        items.append("")
        emit()
        tableView.reloadData()
        let last = IndexPath(row: items.count - 1, section: 0)
        (tableView.cellForRow(at: last)?.contentView.subviews.first as? UITextField)?.becomeFirstResponder()
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 0 else { return nil }
        let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { [weak self] _, _, done in
            self?.items.remove(at: indexPath.row)
            self?.emit()
            self?.tableView.reloadData()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private func index(of field: UITextField) -> Int? {
        let point = field.convert(CGPoint.zero, to: tableView)
        guard let path = tableView.indexPathForRow(at: point), path.section == 0, items.indices.contains(path.row) else { return nil }
        return path.row
    }

    private func emit() {
        handlers.edit(row.path, .list(items.map(LeoConfigValue.string)))
    }
}

/// A string map (an environment's variables): name and value per row, with the
/// variables whose value the daemon holds back listed first, each with
/// Replace and Clear.
final class KeyValueEditorViewController: UITableViewController, SchemaFieldEditorViewController {
    private enum Section: Int, CaseIterable { case secrets, entries, add }

    private var row: LeoConfigFormRow
    private var rows: KeyValueRows
    private let handlers: SchemaFieldHandlers

    init(row: LeoConfigFormRow, handlers: SchemaFieldHandlers) {
        self.row = row
        rows = KeyValueRows(entries: row.value.envEntries)
        self.handlers = handlers
        super.init(style: .insetGrouped)
        title = row.field.label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(row: LeoConfigFormRow) {
        let secretsChanged = row.value.envSecrets != self.row.value.envSecrets
        self.row = row
        let before = rows
        rows.reset(to: row.value.envEntries)
        if isViewLoaded, secretsChanged || rows != before { tableView.reloadData() }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .secrets: row.value.envSecrets.count
        case .entries: rows.rows.count
        default: 1
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .secrets: secretCell(at: indexPath.row)
        case .entries: entryCell(at: indexPath.row)
        default: addCell()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard Section(rawValue: indexPath.section) == .add else { return }
        rows.add()
        emit()
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard Section(rawValue: indexPath.section) == .entries else { return nil }
        let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { [weak self] _, _, done in
            self?.rows.remove(at: indexPath.row)
            self?.emit()
            self?.tableView.reloadData()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    // MARK: cells

    private func addCell() -> UITableViewCell {
        let cell = UITableViewCell()
        var content = UIListContentConfiguration.cell()
        content.text = String(localized: "Add")
        content.image = UIImage(systemName: "plus.circle.fill")
        content.textProperties.color = tableView.tintColor
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "field.editor.add"
        return cell
    }

    private func entryCell(at index: Int) -> UITableViewCell {
        let cell = UITableViewCell()
        let entry = rows.rows[index]
        let name = field(entry.key, placeholder: "Name", id: "field.editor.key.\(index)", monospaced: true) { [weak self] in
            self?.rows.setKey($0, at: index)
            self?.emit()
        }
        let value = field(entry.value, placeholder: "Value", id: "field.editor.value.\(index)", monospaced: false) { [weak self] in
            self?.rows.setValue($0, at: index)
            self?.emit()
        }
        let stack = UIStackView(arrangedSubviews: [name, value])
        stack.distribution = .fillEqually
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
        ])
        return cell
    }

    private func field(_ text: String, placeholder: String, id: String, monospaced: Bool, change: @escaping (String) -> Void) -> UITextField {
        let field = UITextField()
        field.accessibilityIdentifier = id
        field.text = text
        field.placeholder = placeholder
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        if monospaced { field.font = .monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular) }
        field.addAction(UIAction { [weak field] _ in change(field?.text ?? "") }, for: .editingChanged)
        return field
    }

    private func secretCell(at index: Int) -> UITableViewCell {
        let name = row.value.envSecrets.keys.sorted()[index]
        let state = row.value.envSecrets[name] ?? .set
        let cell = UITableViewCell()
        var content = UIListContentConfiguration.valueCell()
        content.text = name
        content.textProperties.font = .monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular)
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "field.editor.secret.\(name)"
        var configuration = UIButton.Configuration.plain()
        configuration.title = SecretText.summary(state)
        configuration.indicator = .popup
        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: secretActions(name, state))
        button.sizeToFit()
        cell.accessoryView = button
        return cell
    }

    private func secretActions(_ name: String, _ state: LeoConfigSecretState) -> [UIAction] {
        let replace = { (title: String) in
            UIAction(title: title) { [weak self] _ in
                self?.handlers.promptSecret(name) { answer in
                    guard let self, let answer, !answer.isEmpty else { return }
                    self.setSecret(name, .secretReplace(answer))
                }
            }
        }
        switch state {
        case .set:
            return [replace("Replace…"), UIAction(title: "Clear", attributes: .destructive) { [weak self] _ in self?.setSecret(name, .secretClear) }]
        case .notSet:
            return [replace("Set…")]
        case .replacing, .clearing:
            return [UIAction(title: "Undo") { [weak self] _ in self?.setSecret(name, .secret(isSet: true)) }]
        }
    }

    private func setSecret(_ name: String, _ value: LeoConfigValue) {
        handlers.edit(row.path, row.value.settingEnvSecret(name, to: value))
    }

    private func emit() {
        handlers.edit(row.path, row.value.replacingEnvEntries(rows.entries))
    }
}
