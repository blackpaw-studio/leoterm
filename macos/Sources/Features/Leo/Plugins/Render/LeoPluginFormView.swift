import AppKit
import LeoKit

/// Native controls for a Form node, backed by `LeoPluginFormModel`.
final class LeoPluginFormView: NSView {
    private let model: LeoPluginFormModel
    private let stack = NSStackView()
    /// Rebuilt with the stack; weak-free because the stack owns the controls.
    private var controls: [String: NSView] = [:]
    private let embedded: Bool

    init(form: LeoPluginNode.Form, emitter: LeoPluginActionEmitter, embedded: Bool) {
        self.embedded = embedded
        self.model = LeoPluginFormModel(form: form, mint: emitter.mint, handler: emitter.handler)
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(
            top: 12, left: LeoPluginRenderStyle.gutter, bottom: 12, right: LeoPluginRenderStyle.gutter)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: stack.fittingSize.height)
    }

    func update(form: LeoPluginNode.Form) {
        model.apply(form: form)
        rebuild()
    }

    // MARK: Build

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        controls = [:]
        let form = model.form
        if let title = form.title, !title.isEmpty {
            stack.addArrangedSubview(LeoPluginRenderStyle.label(title, font: .systemFont(ofSize: 15, weight: .semibold)))
        }
        for field in form.fields {
            let row = makeRow(for: field)
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: LeoPluginRenderStyle.gutter).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -LeoPluginRenderStyle.gutter).isActive = true
        }
        invalidateIntrinsicContentSize()
    }

    private func makeRow(for field: LeoPluginNode.Field) -> NSView {
        switch field.type {
        case .checkbox:
            let box = NSButton(checkboxWithTitle: field.label ?? field.id, target: self, action: #selector(checkboxChanged(_:)))
            box.state = model.values[field.id] == .bool(true) ? .on : .off
            box.identifier = NSUserInterfaceItemIdentifier(field.id)
            controls[field.id] = box
            return box
        case .submit:
            let button = NSButton(title: field.label ?? "Submit", target: self, action: #selector(submitTapped(_:)))
            button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier(field.id)
            button.isEnabled = field.action != nil
            controls[field.id] = button
            return button
        case .text, .picker, .textArea:
            let control = makeInput(for: field)
            controls[field.id] = control
            guard let label = field.label, !label.isEmpty else { return control }
            let caption = LeoPluginRenderStyle.label(label, font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
            let column = NSStackView(views: [caption, control])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            control.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
            control.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
            return column
        }
    }

    private func makeInput(for field: LeoPluginNode.Field) -> NSView {
        switch field.type {
        case .picker:
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: field.options.map(\.title))
            if case .string(let current) = model.values[field.id], let index = field.options.firstIndex(where: { $0.value == current }) {
                popup.selectItem(at: index)
            }
            popup.target = self
            popup.action = #selector(pickerChanged(_:))
            popup.identifier = NSUserInterfaceItemIdentifier(field.id)
            return popup
        case .textArea:
            let text = NSTextView()
            text.isRichText = false
            text.font = .systemFont(ofSize: 13)
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false
            text.textContainerInset = NSSize(width: 4, height: 4)
            text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.identifier = NSUserInterfaceItemIdentifier(field.id)
            text.delegate = self
            if case .string(let current) = model.values[field.id] { text.string = current }
            let scroll = NSScrollView()
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .bezelBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.heightAnchor.constraint(equalToConstant: 88).isActive = true
            return scroll
        default:
            let input = NSTextField()
            input.placeholderString = field.placeholder
            input.isEditable = true
            input.bezelStyle = .roundedBezel
            input.identifier = NSUserInterfaceItemIdentifier(field.id)
            input.delegate = self
            input.target = self
            // Return in a single-line field submits the form's first submit button.
            input.action = #selector(returnInField)
            if case .string(let current) = model.values[field.id] { input.stringValue = current }
            return input
        }
    }

    // MARK: Actions

    @objc private func checkboxChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        model.setChecked(sender.state == .on, for: id)
    }

    @objc private func pickerChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue,
              let field = model.form.fields.first(where: { $0.id == id }),
              field.options.indices.contains(sender.indexOfSelectedItem) else { return }
        model.setChoice(field.options[sender.indexOfSelectedItem].value, for: id)
    }

    @objc private func submitTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        commitPendingEdits()
        model.submit(fieldID: id, origin: .click)
    }

    @objc private func returnInField() {
        guard let submit = model.form.fields.first(where: { $0.type == .submit && $0.action != nil }) else { return }
        commitPendingEdits()
        model.submit(fieldID: submit.id, origin: .keyboard)
    }

    /// Pushes whatever is mid-edit into the model before a submit reads it.
    private func commitPendingEdits() {
        window?.makeFirstResponder(nil)
    }
}

extension LeoPluginFormView: NSTextFieldDelegate, NSTextViewDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let id = field.identifier?.rawValue else { return }
        model.setText(field.stringValue, for: id)
    }

    func textDidChange(_ notification: Notification) {
        guard let text = notification.object as? NSTextView, let id = text.identifier?.rawValue else { return }
        model.setText(text.string, for: id)
    }
}
