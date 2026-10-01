import AppKit

/// The pane's header: a pop-up of recently opened files (the open one
/// selected; choosing another switches to it), the Edited / read-only
/// state, the language, and a close button. Names and folders come from
/// terminal output or a remote host, so they're shown sanitized.
final class LeoEditorHeaderView: NSView {
    var onSelectRecent: (LeoEditorFileID) -> Void = { _ in }
    var onClose: () -> Void = {}

    private let recentsButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stateLabel = NSTextField(labelWithString: "")
    private let lockImage = NSImageView()
    private let languageLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var recents: [LeoEditorFileID] = []

    /// The control the pane centres the header on when it insets it (B-100).
    var closeControl: NSView { closeButton }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { nil }

    func update(document: LeoEditorDocument?, recents: [LeoEditorFileID]) {
        self.recents = recents
        let menu = NSMenu()
        for (index, fileID) in recents.enumerated() {
            let item = NSMenuItem(title: Self.title(for: fileID), action: #selector(selectRecent(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.toolTip = Self.location(of: fileID)
            item.attributedTitle = Self.menuTitle(for: fileID)
            menu.addItem(item)
        }
        recentsButton.menu = menu
        if let document, let index = recents.firstIndex(of: document.fileID) {
            recentsButton.selectItem(at: index)
            recentsButton.toolTip = Self.location(of: document.fileID)
        }
        recentsButton.setAccessibilityLabel(Self.accessibilityLabel(forOpen: document?.fileID))
        stateLabel.stringValue = document?.isDirty == true ? "Edited" : ""
        lockImage.isHidden = document?.isReadOnly != true
        languageLabel.stringValue = document?.language.displayName ?? ""
    }

    private func build() {
        recentsButton.isBordered = false
        recentsButton.controlSize = .small
        recentsButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        recentsButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        recentsButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (recentsButton.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle

        for label in [stateLabel, languageLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        lockImage.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Read-only")
        lockImage.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .regular)
        lockImage.contentTintColor = .secondaryLabelColor
        lockImage.toolTip = "Read-only"
        lockImage.isHidden = true

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Editor")
        closeButton.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .medium)
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close Editor (⌘W)"
        closeButton.target = self
        closeButton.action = #selector(close(_:))

        let stack = NSStackView(views: [recentsButton, stateLabel, lockImage, NSView(), languageLabel, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @objc private func selectRecent(_ sender: NSMenuItem) {
        guard recents.indices.contains(sender.tag) else { return }
        onSelectRecent(recents[sender.tag])
    }

    @objc private func close(_ sender: Any?) {
        onClose()
    }

    /// `name  ~/dir` (the folder in secondary colour), plus the host when
    /// it isn't this Mac.
    static func title(for fileID: LeoEditorFileID) -> String {
        LeoSFTPServerText.sanitized(fileID.name)
    }

    static func accessibilityLabel(forOpen fileID: LeoEditorFileID?) -> String {
        fileID.map { "Open file: \(title(for: $0))" } ?? "Recent files"
    }

    static func menuTitle(for fileID: LeoEditorFileID) -> NSAttributedString {
        let title = NSMutableAttributedString(string: Self.title(for: fileID), attributes: [.font: NSFont.menuFont(ofSize: 0)])
        title.append(NSAttributedString(string: "  " + location(of: fileID), attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return title
    }

    static func location(of fileID: LeoEditorFileID) -> String {
        let directory = (fileID.path as NSString).deletingLastPathComponent
        let shown = LeoSFTPServerText.sanitized(fileID.host == .local ? (directory as NSString).abbreviatingWithTildeInPath : directory)
        return fileID.host == .local ? shown : "\(shown) — \(fileID.host.displayName)"
    }
}
