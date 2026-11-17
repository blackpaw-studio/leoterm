import AppKit
import LeoKit

/// What File ▸ Save Page as PDF… / Save Full-Page Screenshot… asks (B-406):
/// one path in the agent's workspace. A path field rather than a save
/// panel, because NSSavePanel can't browse a remote machine over SFTP.
@MainActor final class LeoBrowserSaveSheetModel {
    let kind: LeoBrowserCaptureKind
    /// The path as typed, before trimming.
    private(set) var path: String
    /// Why the path can't be saved to, as a sentence; nil when it can.
    private(set) var problem: String?
    /// The default name's stem, so typing replaces just the name.
    let initialSelection: NSRange
    private let check: (String) -> String?

    /// `check` returns what is wrong with a trimmed path, or nil.
    init(kind: LeoBrowserCaptureKind, defaultName: String, check: @escaping (String) -> String?) {
        self.kind = kind
        self.check = check
        let folder = LeoBrowserCapturePath.defaultFolder + "/"
        path = folder + defaultName
        initialSelection = NSRange(location: folder.utf16.count, length: (defaultName as NSString).deletingPathExtension.utf16.count)
        problem = check(path)
    }

    var title: String {
        switch kind {
        case .pdf: "Save Page as PDF"
        case .png: "Save Full-Page Screenshot"
        }
    }

    var canSave: Bool { problem == nil }

    /// What is saved to: the path without surrounding whitespace.
    var trimmedPath: String { path.trimmingCharacters(in: .whitespacesAndNewlines) }

    func update(path: String) {
        self.path = path
        problem = check(trimmedPath)
    }
}

/// The sheet itself: a title, a line on where files go, the path field, a
/// line saying what is wrong with the path, and Cancel / Save. Save is the
/// default button and is off while the path has a problem; Esc cancels.
@MainActor final class LeoBrowserSaveSheet: NSObject, NSTextFieldDelegate {
    static let fieldWidth: CGFloat = 360

    let model: LeoBrowserSaveSheetModel
    let window: NSWindow
    let field = NSTextField()
    /// One line, always there, so the sheet doesn't jump as it fills in.
    let problemLabel = NSTextField(labelWithString: "")
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    /// The trimmed path on Save, nil on Cancel. Called once.
    var onFinish: ((String?) -> Void)?

    init(model: LeoBrowserSaveSheetModel) {
        self.model = model
        window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        build()
        refresh()
    }

    func present(on parent: NSWindow) {
        parent.beginSheet(window) { _ in }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = model.initialSelection
    }

    @objc func save(_ sender: Any?) {
        guard model.canSave else { return NSSound.beep() }
        finish(model.trimmedPath)
    }

    @objc func cancel(_ sender: Any?) {
        finish(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        model.update(path: field.stringValue)
        refresh()
    }

    private func finish(_ path: String?) {
        window.sheetParent?.endSheet(window)
        let onFinish = onFinish
        self.onFinish = nil
        onFinish?(path)
    }

    private func refresh() {
        saveButton.isEnabled = model.canSave
        problemLabel.stringValue = model.problem ?? ""
        problemLabel.toolTip = model.problem
    }

    private func build() {
        window.title = model.title
        let title = NSTextField(labelWithString: model.title)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let note = NSTextField(wrappingLabelWithString:
            "Saved in the agent’s workspace, on its machine. Folders are made as needed, and nothing is overwritten.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        field.stringValue = model.path
        field.delegate = self
        field.setAccessibilityLabel("Path in the workspace")
        field.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        let fieldLabel = NSTextField(labelWithString: "Path:")
        let fieldRow = NSStackView(views: [fieldLabel, field])
        fieldRow.spacing = 8
        fieldRow.alignment = .firstBaseline

        problemLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        problemLabel.textColor = .systemRed
        problemLabel.lineBreakMode = .byTruncatingTail
        problemLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.spacing = 12
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, buttons])

        let stack = NSStackView(views: [title, note, fieldRow, problemLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: problemLabel)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        note.preferredMaxLayoutWidth = Self.fieldWidth + 48
        buttonRow.widthAnchor.constraint(equalTo: fieldRow.widthAnchor).isActive = true
        problemLabel.widthAnchor.constraint(equalTo: fieldRow.widthAnchor).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.initialFirstResponder = field
    }
}
