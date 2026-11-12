import AppKit
import Combine
import LeoKit

/// The Terminal tab's summary: `· <dir>` after the title, where `<dir>` is
/// the shell's directory (OSC 7) once it has reported one, else the agent's
/// workspace, shortened like the Status plugin's paths.
@MainActor final class LeoDrawerSummaryView: NSView, LeoAgentPaneSummaryView {
    private let identity: LeoAgentIdentity
    private let environment: LeoDrawerEnvironment
    private let key: LeoAgentID
    private let label = NSTextField(labelWithString: "")
    private var poolSubscription: AnyCancellable?
    private var pwdSubscription: AnyCancellable?
    private var observed: ObjectIdentifier?
    /// Told when the text (so the width) changes, for the tab bar's fit.
    var onChange: () -> Void = {}

    init(identity: LeoAgentIdentity, environment: LeoDrawerEnvironment) {
        self.identity = identity
        self.environment = environment
        key = LeoDrawerEnvironment.key(for: identity)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setAccessibilityElement(false)
        addSubview(label)
        poolSubscription = environment.pool.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.follow() }
        follow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var summaryWidth: CGFloat { label.stringValue.isEmpty ? 0 : ceil(label.intrinsicContentSize.width) }
    var summaryHeight: CGFloat { ceil(label.intrinsicContentSize.height) }

    override func layout() {
        super.layout()
        let height = summaryHeight
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    /// Follows the running shell's `pwd` (weakly: the surface must stay free to go), or shows the workspace.
    private func follow() {
        guard case .running(let surface) = environment.pool.state(for: key) else {
            pwdSubscription = nil
            observed = nil
            refresh(pwd: nil)
            return
        }
        guard observed != ObjectIdentifier(surface) else { return }
        observed = ObjectIdentifier(surface)
        pwdSubscription = surface.$pwd.sink { [weak self] in self?.refresh(pwd: $0) }
    }

    private func refresh(pwd: String?) {
        let home = identity.host == .local ? NSHomeDirectory() : nil
        let path = LeoDrawerPath.summary(pwd: pwd, workspace: identity.workspace, home: home)
        let text = path.map { "· \($0)" } ?? ""
        guard text != label.stringValue else { return }
        label.stringValue = text
        toolTip = path
        needsLayout = true
        onChange()
    }
}
