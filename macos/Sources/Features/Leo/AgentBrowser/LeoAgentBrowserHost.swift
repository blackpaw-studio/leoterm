import AppKit

/// Where agent-browser pages live (E5). Every tab's web view is always in
/// a window: in the pane showing its browser when it is the active tab and
/// a pane is on screen, otherwise in the off-screen parking window. Moving
/// a web view between windows keeps the page as it is: nothing reloads.
///
/// Panes report their slots as they come on screen and leave. When several
/// windows show the same browser, the slot shown last has the page and the
/// others say it is shown in another window; when that one leaves, the one
/// shown before it takes the page back.
@MainActor final class LeoAgentBrowserHost {
    /// The parking window's size until a pane gives it a real one.
    static let defaultSize = CGSize(width: 1_280, height: 800)

    private struct Viewer {
        weak var slot: LeoAgentBrowserSlot?
        weak var source: (any LeoAgentBrowserPaneSource)?
    }

    /// Made the first time a page needs it.
    private(set) lazy var parking = makeParking()
    private let makeParking: @MainActor () -> LeoAgentBrowserParkingWindow
    /// Slots on screen, in the order they were shown; the last one showing a
    /// browser has its page.
    private var viewers: [Viewer] = []

    init(parking: @escaping @MainActor @autoclosure () -> LeoAgentBrowserParkingWindow = LeoAgentBrowserParkingWindow(size: LeoAgentBrowserHost.defaultSize)) {
        makeParking = parking
    }

    /// A new tab's view waits in the parking window until a pane shows it.
    func adopt(_ view: NSView) {
        parking.park(view)
    }

    /// A closed tab's view leaves every window.
    func release(_ view: NSView) {
        view.removeFromSuperview()
    }

    /// `slot` came on screen showing `source`: it takes the page from any
    /// other window showing it.
    func show(_ source: any LeoAgentBrowserPaneSource, in slot: LeoAgentBrowserSlot) {
        viewers.removeAll { $0.slot == nil || $0.slot === slot }
        viewers.append(Viewer(slot: slot, source: source))
        place(source)
    }

    /// `slot` left the screen (its row was switched away, its pane hidden or
    /// its window closed): its page goes to the next window showing the
    /// browser, or back to the parking window.
    func hide(_ slot: LeoAgentBrowserSlot) {
        let source = viewers.first { $0.slot === slot }?.source
        viewers.removeAll { $0.slot == nil || $0.slot === slot }
        slot.isShownElsewhere = false
        if let hosted = slot.hostedView { parking.park(hosted) }
        if let source { place(source) }
    }

    /// `source`'s active tab changed: the slot showing it shows the new one.
    func refresh(_ source: any LeoAgentBrowserPaneSource) {
        place(source)
    }

    private func place(_ source: any LeoAgentBrowserPaneSource) {
        let slots = viewers.filter { $0.source === source }.compactMap(\.slot)
        guard let winner = slots.last else { return }
        for other in slots.dropLast() {
            if let hosted = other.hostedView { parking.park(hosted) }
            other.isShownElsewhere = true
        }
        winner.isShownElsewhere = false
        let active = source.activeView
        if let hosted = winner.hostedView, hosted !== active { parking.park(hosted) }
        if let active, winner.hostedView !== active { winner.host(active) }
        if winner.bounds.width > 0, winner.bounds.height > 0 { parking.resize(to: winner.bounds.size) }
    }
}

/// The spot in a browser pane where the active page shows (E5). It tells
/// its pane when it comes on screen or leaves -- moved into or out of a
/// window, hidden or shown with an ancestor, or its window closing -- and
/// shows "Shown in another window" while another window has the page.
final class LeoAgentBrowserSlot: NSView {
    /// True when the slot is in an open window and not hidden.
    var onVisibilityChange: ((Bool) -> Void)?
    /// Another window shows the page.
    var isShownElsewhere = false {
        didSet { elsewhereLabel.isHidden = !isShownElsewhere }
    }

    /// The page shown here, while it is.
    var hostedView: NSView? { hosted?.superview === self ? hosted : nil }

    private weak var hosted: NSView?
    private let elsewhereLabel = NSTextField(labelWithString: "Shown in another window")
    private var isVisible = false
    private var windowCloseObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        elsewhereLabel.textColor = .secondaryLabelColor
        elsewhereLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        elsewhereLabel.isHidden = true
        elsewhereLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(elsewhereLabel)
        NSLayoutConstraint.activate([
            elsewhereLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            elsewhereLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Shows `view`, filling the slot.
    func host(_ view: NSView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: elsewhereLabel)
        hosted = view
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        windowCloseObserver.map(NotificationCenter.default.removeObserver)
        windowCloseObserver = nil
        guard let newWindow else { return }
        // `queue: nil` and no hop: willClose is posted on the main thread
        // while the window can still hand the page back.
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: newWindow, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(closing: true) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    override func viewDidHide() {
        super.viewDidHide()
        update()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        update()
    }

    private func update(closing: Bool = false) {
        let nowVisible = !closing && window != nil && !isHiddenOrHasHiddenAncestor
        guard nowVisible != isVisible else { return }
        isVisible = nowVisible
        onVisibilityChange?(nowVisible)
    }
}
