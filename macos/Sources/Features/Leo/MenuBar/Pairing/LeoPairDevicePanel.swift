import AppKit

/// Owns the "Pair a Device" window. Each time it opens it starts a fresh
/// `LeoPairingModel`, and closing the window stops it, so no code refreshes in
/// the background. Layout only: the decisions are the model's and the QR's.
/// A TDD exception; verify by screenshot.
@MainActor final class LeoPairDevicePanelController: NSObject, NSWindowDelegate {
    private let makeModel: () -> LeoPairingModel
    private var window: NSWindow?
    private var model: LeoPairingModel?
    private var content: LeoPairDeviceContentView?

    init(makeModel: @escaping () -> LeoPairingModel) {
        self.makeModel = makeModel
    }

    func show() {
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = makeModel()
        let content = LeoPairDeviceContentView(
            enableWeb: { [weak model] in model?.enableWebAccess() },
            retry: { [weak model] in model?.start() },
            sizeChanged: { [weak self] in self?.fitWindow() }
        )
        let window = self.window ?? Self.makeWindow()
        window.delegate = self
        window.contentView = content
        model.onChange = { [weak content, weak model] in content?.render($0, webNotice: model?.webNotice) }
        self.model = model
        self.content = content
        self.window = window
        content.render(model.state, webNotice: model.webNotice)
        fitWindow()
        model.start()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.stop()
        model?.onChange = nil
        model = nil
        content = nil
    }

    private func fitWindow() {
        guard let window, let content else { return }
        let size = NSSize(width: LeoPairDeviceContentView.width, height: content.fittingSize.height)
        window.setContentSize(size)
    }

    private static func makeWindow() -> NSWindow {
        let window = LeoPairDeviceWindow(
            contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true
        )
        window.title = "Pair a Device"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("")
        return window
    }
}

/// Esc closes it, as it does for a sheet or alert.
private final class LeoPairDeviceWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// The panel's contents for each `LeoPairingModel.State`.
@MainActor final class LeoPairDeviceContentView: NSView {
    static let width: CGFloat = 380
    private static let qrSide: CGFloat = 220
    private static let inset: CGFloat = 24

    private let enableWeb: () -> Void
    private let retry: () -> Void
    private let sizeChanged: () -> Void
    private let stack = NSStackView()
    private var copyButton: NSButton?
    private var currentCode = ""

    init(enableWeb: @escaping () -> Void, retry: @escaping () -> Void, sizeChanged: @escaping () -> Void) {
        self.enableWeb = enableWeb
        self.retry = retry
        self.sizeChanged = sizeChanged
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func render(_ state: LeoPairingModel.State, webNotice: String? = nil) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        copyButton = nil
        switch state {
        case .loading: showProgress("Getting a pairing code…")
        case .refreshing: showProgress("Refreshing…")
        case .enablingWeb: showProgress(LeoPairingCopy.enablingTitle, detail: LeoPairingCopy.enablingDetail)
        case .ready(let payload): showPairing(payload, webNotice: webNotice)
        case .webDisabled: showWebDisabled()
        case .failed(let message): showFailure(message)
        }
        layoutSubtreeIfNeeded()
        sizeChanged()
    }

    // MARK: States

    private func showProgress(_ text: String, detail: String? = nil) {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        add(spinner)
        add(Self.label(text, font: .preferredFont(forTextStyle: .body), color: .secondaryLabelColor))
        if let detail {
            add(Self.label(detail, font: .preferredFont(forTextStyle: .callout), color: .tertiaryLabelColor))
        }
    }

    private func showPairing(_ payload: LeoPairingPayload, webNotice: String?) {
        currentCode = payload.pairingCode
        add(Self.label(
            "Scan this code with Leo on your phone, or enter the code and an address by hand.",
            font: .preferredFont(forTextStyle: .callout), color: .secondaryLabelColor
        ))
        add(qrView(for: payload.qrPayload))

        add(Self.label("Pairing code", font: .preferredFont(forTextStyle: .caption1), color: .secondaryLabelColor))
        let code = Self.label(
            payload.pairingCode, font: .monospacedSystemFont(ofSize: 24, weight: .semibold), color: .labelColor
        )
        code.isSelectable = true
        add(code)
        let copy = NSButton(title: "Copy Code", target: self, action: #selector(copyCode))
        copy.bezelStyle = .rounded
        copyButton = copy
        add(copy)

        if !payload.urls.isEmpty {
            add(Self.label("Addresses", font: .preferredFont(forTextStyle: .caption1), color: .secondaryLabelColor))
            for url in payload.urls {
                let label = Self.label(url, font: .monospacedSystemFont(ofSize: 12, weight: .regular), color: .labelColor)
                label.isSelectable = true
                add(label)
            }
        }
        payload.warnings.forEach { add(warningRow($0)) }
        if let webNotice {
            add(Self.label(webNotice, font: .preferredFont(forTextStyle: .callout), color: .labelColor))
        }

        let time = payload.expiresAt.formatted(date: .omitted, time: .shortened)
        add(Self.label(
            "This code refreshes at \(time).", font: .preferredFont(forTextStyle: .caption1), color: .tertiaryLabelColor
        ))
    }

    private func showWebDisabled() {
        add(Self.symbol("network.slash", color: .secondaryLabelColor))
        add(Self.label("Web access is off", font: .preferredFont(forTextStyle: .headline), color: .labelColor))
        add(Self.label(
            "Pairing a device needs the daemon’s web listener.\n\n\(LeoPairingCopy.enableExplanation)",
            font: .preferredFont(forTextStyle: .callout), color: .secondaryLabelColor
        ))
        let button = NSButton(title: "Enable Web Access", target: self, action: #selector(enableWebTapped))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        add(button)
    }

    private func showFailure(_ message: String) {
        add(Self.symbol("exclamationmark.triangle.fill", color: .systemYellow))
        add(Self.label("Couldn’t get a pairing code", font: .preferredFont(forTextStyle: .headline), color: .labelColor))
        let detail = Self.label(message, font: .preferredFont(forTextStyle: .callout), color: .secondaryLabelColor)
        detail.isSelectable = true
        add(detail)
        let button = NSButton(title: "Try Again", target: self, action: #selector(retryTapped))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        add(button)
    }

    // MARK: Pieces

    private func qrView(for payload: String) -> NSView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel("QR code for pairing")
        if let image = LeoQRCode.image(for: payload, side: Self.qrSide * (window?.backingScaleFactor ?? 2)) {
            view.image = NSImage(cgImage: image, size: NSSize(width: Self.qrSide, height: Self.qrSide))
        }
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.masksToBounds = true
        view.widthAnchor.constraint(equalToConstant: Self.qrSide).isActive = true
        view.heightAnchor.constraint(equalToConstant: Self.qrSide).isActive = true
        return view
    }

    private func warningRow(_ text: String) -> NSView {
        let icon = Self.symbol("exclamationmark.triangle.fill", color: .systemYellow, pointSize: 13)
        let label = Self.label(text, font: .preferredFont(forTextStyle: .callout), color: .labelColor)
        label.alignment = .left
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        return row
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        if view is NSTextField {
            view.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width - 2 * Self.inset).isActive = true
        }
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.alignment = .center
        label.isSelectable = false
        return label
    }

    private static func symbol(_ name: String, color: NSColor, pointSize: CGFloat = 28) -> NSImageView {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.init(paletteColors: [color]))
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage())
        view.setAccessibilityElement(false)
        return view
    }

    // MARK: Actions

    @objc private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentCode, forType: .string)
        copyButton?.title = "Copied"
    }

    @objc private func enableWebTapped() { enableWeb() }
    @objc private func retryTapped() { retry() }
}
