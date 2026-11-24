import AppKit

/// The drop target over the terminal while a dock tab is dragged (B-440).
/// It is hidden, and so takes no clicks or file drops, except between
/// `begin` and `end`. It shows one zone: the half of the terminal along the
/// edge the dragged pane isn't on. The zone appears once the drag is over
/// the terminal and fills with the accent colour while the cursor is in it;
/// a drop there calls `onDrop`, a drop anywhere else does nothing.
final class LeoDockDropOverlay: NSView {
    private struct Drag {
        let pane: LeoDockPane
        let edge: LeoDockEdge
    }

    private static let zoneInset: CGFloat = 8
    private static let zoneCornerRadius: CGFloat = 10
    private static let hintAlpha: CGFloat = 0.1
    private static let armedAlpha: CGFloat = 0.3

    /// A drop landed in the zone.
    var onDrop: (LeoDockPane, LeoDockEdge) -> Void = { _, _ in }

    private var drag: Drag?
    private var isDragOver = false {
        didSet { if isDragOver != oldValue { needsDisplay = true } }
    }

    private var isArmed = false {
        didSet { if isArmed != oldValue { needsDisplay = true } }
    }

    init() {
        super.init(frame: .zero)
        isHidden = true
        setAccessibilityElement(false)
        registerForDraggedTypes([LeoDockPaneDrag.pasteboardType])
    }

    required init?(coder: NSCoder) { nil }

    /// Shows the zone for a drag of `pane`, landing on `edge`.
    func begin(pane: LeoDockPane, edge: LeoDockEdge) {
        drag = Drag(pane: pane, edge: edge)
        isDragOver = false
        isArmed = false
        isHidden = false
    }

    func end() {
        drag = nil
        isDragOver = false
        isArmed = false
        isHidden = true
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        track(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        track(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDragOver = false
        isArmed = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let drag = accepted(sender), isInZone(sender, edge: drag.edge) else { return false }
        onDrop(drag.pane, drag.edge)
        return true
    }

    /// Backstop: whatever ends the session also ends the overlay.
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        end()
    }

    private func track(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard let drag = accepted(info) else {
            isDragOver = false
            isArmed = false
            return []
        }
        isDragOver = true
        isArmed = isInZone(info, edge: drag.edge)
        return isArmed ? .move : []
    }

    /// The active drag, if `info` is it: the same pane, started in this window.
    private func accepted(_ info: any NSDraggingInfo) -> Drag? {
        guard let drag, let window,
              LeoDockPaneDrag.pane(from: info.draggingPasteboard) == drag.pane,
              (info.draggingSource as? NSView)?.window === window else { return nil }
        return drag
    }

    private func isInZone(_ info: any NSDraggingInfo, edge: LeoDockEdge) -> Bool {
        LeoDockDropZone.contains(convert(info.draggingLocation, from: nil), edge: edge, in: bounds)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard isDragOver, let edge = drag?.edge else { return }
        let zone = LeoDockDropZone.frame(for: edge, in: bounds).insetBy(dx: Self.zoneInset, dy: Self.zoneInset)
        let path = NSBezierPath(roundedRect: zone, xRadius: Self.zoneCornerRadius, yRadius: Self.zoneCornerRadius)
        NSColor.controlAccentColor.withAlphaComponent(isArmed ? Self.armedAlpha : Self.hintAlpha).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(isArmed ? 1 : 0.5).setStroke()
        path.lineWidth = 2
        path.stroke()

        let label = NSAttributedString(string: LeoDockDropZone.title(for: edge), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold),
            .foregroundColor: isArmed ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: zone.midX - size.width / 2, y: zone.midY - size.height / 2))
    }
}

/// The terminal with the drop overlay pinned above it (B-440): the first
/// item of the terminal column's split.
final class LeoDockDropHostViewController: NSViewController {
    let terminal: NSViewController
    let overlay = LeoDockDropOverlay()

    init(terminal: NSViewController) {
        self.terminal = terminal
        super.init(nibName: nil, bundle: nil)
        addChild(terminal)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        view.setAccessibilityElement(false)
        for child in [terminal.view, overlay] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                child.topAnchor.constraint(equalTo: view.topAnchor),
                child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
    }
}
