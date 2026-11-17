import AppKit

/// Safari's find bar for the browser pane (B-407): a search field, the match
/// count, previous / next and Done, under the toolbar and above the page.
/// Return steps forward, ⇧Return back and Esc closes it.
final class LeoBrowserFindBar: NSView, NSSearchFieldDelegate {
    var onQueryChange: (String) -> Void = { _ in }
    var onStep: (LeoFindDirection) -> Void = { _ in }
    var onClose: () -> Void = {}

    let field = NSSearchField()
    let countLabel = NSTextField(labelWithString: "")
    let stepper = NSSegmentedControl()
    let doneButton = NSButton()
    private let separator = NSBox()

    private static let insets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
    private static let fieldWidth: CGFloat = 220

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { nil }

    /// Shows the controller's state; the field keeps what the user is typing.
    func update(query: String, label: String) {
        // Setting the field's string ends its editing, so leave it be while
        // the text the user is typing is already the query.
        if (field.currentEditor()?.string ?? field.stringValue) != query { field.stringValue = query }
        countLabel.stringValue = label
        countLabel.isHidden = label.isEmpty
        stepper.setEnabled(!query.isEmpty, forSegment: 0)
        stepper.setEnabled(!query.isEmpty, forSegment: 1)
        field.setAccessibilityValueDescription(label.isEmpty ? nil : label)
    }

    /// Puts the cursor in the field with its text selected, as ⌘F does.
    func focusField() {
        guard let window else { return }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let isBackward = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            onStep(isBackward ? .previous : .next)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose()
            return true
        default:
            return false
        }
    }

    // MARK: Layout

    private func build() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find in page")
        isHidden = true

        field.placeholderString = "Find in Page"
        field.delegate = self
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.sendsSearchStringImmediately = true
        // The clear button sets the field to "" without a text-change notice;
        // the action reaches the same path. Return never gets here (see
        // `control(_:textView:doCommandBy:)`), and the controller ignores a
        // query it already has.
        field.target = self
        field.action = #selector(fieldChanged(_:))
        field.setAccessibilityLabel("Find in page")
        field.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true

        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setAccessibilityElement(false)

        stepper.segmentStyle = .separated
        stepper.trackingMode = .momentary
        stepper.controlSize = .small
        stepper.segmentCount = 2
        for (index, symbol, label) in [(0, "chevron.left", "Previous match"), (1, "chevron.right", "Next match")] {
            stepper.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label), forSegment: index)
            stepper.setImageScaling(.scaleProportionallyDown, forSegment: index)
            stepper.setWidth(26, forSegment: index)
            stepper.setToolTip(label, forSegment: index)
        }
        stepper.target = self
        stepper.action = #selector(stepped(_:))

        doneButton.title = "Done"
        doneButton.bezelStyle = .push
        doneButton.controlSize = .small
        doneButton.target = self
        doneButton.action = #selector(done(_:))
        doneButton.setAccessibilityLabel("Close find bar")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [field, countLabel, stepper, spacer, doneButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Self.insets.top),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.insets.left),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.insets.right),
            row.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -Self.insets.bottom),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func fieldChanged(_ sender: NSSearchField) {
        onQueryChange(sender.stringValue)
    }

    @objc private func stepped(_ sender: NSSegmentedControl) {
        onStep(sender.selectedSegment == 0 ? .previous : .next)
    }

    @objc private func done(_ sender: Any?) {
        onClose()
    }
}
