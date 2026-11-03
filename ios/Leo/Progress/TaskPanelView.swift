import LeoFeatures
import LeoKit
import UIKit

/// Chat panel B: a translucent card docked top-right over the Chats split.
/// Collapsed it is one header line ("Tasks 3 · 62%"); expanded it lists every
/// running and failed task across the fleet. Tapping a row opens that agent's
/// thread; a failed row has Dismiss. Hidden when there is nothing to show.
final class TaskPanelView: UIView {
    var onToggle: () -> Void = {}
    var onOpen: (AgentRef) -> Void = { _ in }
    var onDismiss: (TaskPanelRow) -> Void = { _ in }

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let headerButton = UIButton(type: .system)
    private let rows = UIStackView()
    private let scroll = UIScrollView()
    private var lastRender: TaskPanelRenderKey?
    private var rowViews: [TaskPanelRowView] = []

    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.cgColor
        accessibilityIdentifier = "tasks.panel"

        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        var configuration = UIButton.Configuration.plain()
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 6
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 12)
        headerButton.configuration = configuration
        headerButton.contentHorizontalAlignment = .leading
        headerButton.accessibilityIdentifier = "tasks.panel.header"
        headerButton.addAction(UIAction { [weak self] _ in self?.onToggle() }, for: .touchUpInside)
        rows.axis = .vertical
        stack.axis = .vertical
        stack.addArrangedSubview(headerButton)
        scroll.addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = true
        stack.addArrangedSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(stack)
        // The list is as tall as its rows; the card caps it (see `didMoveToSuperview`) and scrolls.
        let fitsRows = scroll.heightAnchor.constraint(equalTo: rows.heightAnchor)
        // Below the labels' compression resistance (750): the card never squeezes a row's text, it scrolls.
        fitsRows.priority = .defaultLow
        NSLayoutConstraint.activate([
            fitsRows,
            rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rows.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The height of the card collapsed to its header, whatever it shows now.
    var collapsedHeight: CGFloat { headerButton.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height }

    /// At most 40% of the safe-area height, so a long list scrolls instead of covering the chat.
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard let superview else { return }
        scroll.heightAnchor.constraint(lessThanOrEqualTo: superview.safeAreaLayoutGuide.heightAnchor, multiplier: 0.4).isActive = true
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        layer.borderColor = UIColor.separator.cgColor
    }

    func render(header: String, rows items: [TaskPanelRow], isCollapsed: Bool, now: Date) {
        let key = TaskPanelRenderKey(header: header, rows: items, isCollapsed: isCollapsed, now: now)
        let plan = TaskPanelRenderPlan(previous: lastRender, next: key)
        lastRender = key
        switch plan {
        case .skip: return
        case .relabel:
            // Only the clock moved: refresh the labels, keep the views (and their sliding bars).
            rowViews.forEach { $0.relabel(now: now) }
            return
        case .rebuild: break
        }
        isHidden = items.isEmpty
        var configuration = headerButton.configuration
        configuration?.attributedTitle = AttributedString(header, attributes: AttributeContainer([.font: UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)]))
        configuration?.image = UIImage(systemName: isCollapsed ? "chevron.down" : "chevron.up")
        configuration?.baseForegroundColor = .label
        headerButton.configuration = configuration
        headerButton.accessibilityLabel = header
        headerButton.accessibilityHint = isCollapsed ? String(localized: "Expands the task list") : String(localized: "Collapses the task list")
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowViews = []
        scroll.isHidden = isCollapsed
        guard !isCollapsed else { return }
        for item in items {
            let view = TaskPanelRowView(item, now: now, open: { [weak self] in self?.onOpen(item.ref) }, dismiss: { [weak self] in self?.onDismiss(item) })
            rowViews.append(view)
            rows.addArrangedSubview(view)
        }
    }
}

private final class TaskPanelRowView: UIView {
    private let detail = UILabel()
    private let row: TaskPanelRow

    /// Rewrites the detail line (elapsed, ETA) for a new clock; nothing else moves.
    func relabel(now: Date) {
        detail.text = Agent.taskDetailLine(row.task, etaAt: row.etaAt, now: now)
    }

    init(_ row: TaskPanelRow, now: Date, open: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.row = row
        super.init(frame: .zero)
        accessibilityIdentifier = "tasks.panel.row.\(row.ref.name).\(row.task.id)"
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let emoji = UILabel()
        emoji.text = row.emoji ?? "🤖"
        emoji.font = .preferredFont(forTextStyle: .body)
        emoji.setContentHuggingPriority(.required, for: .horizontal)
        let name = UILabel()
        name.text = row.displayName
        name.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        name.textColor = .secondaryLabel
        let title = UILabel()
        title.text = row.task.title
        title.font = .preferredFont(forTextStyle: .footnote).withWeight(.medium)
        detail.text = Agent.taskDetailLine(row.task, etaAt: row.etaAt, now: now)
        detail.font = .preferredFont(forTextStyle: .caption2)
        detail.textColor = row.task.state == .failed ? .systemRed : .secondaryLabel
        detail.numberOfLines = 2
        let bar = TaskBarView()
        bar.apply(Agent.style(of: row.task))

        let text = UIStackView(arrangedSubviews: [name, title, bar, detail])
        text.axis = .vertical
        text.spacing = 3
        text.setCustomSpacing(5, after: title)
        let line = UIStackView(arrangedSubviews: [emoji, text])
        line.alignment = .top
        line.spacing = 8
        if row.task.state == .failed {
            var configuration = UIButton.Configuration.plain()
            configuration.title = String(localized: "Dismiss")
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { $0.merging(AttributeContainer([.font: UIFont.preferredFont(forTextStyle: .caption1)])) }
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 0)
            let button = UIButton(configuration: configuration)
            button.addAction(UIAction { _ in dismiss() }, for: .touchUpInside)
            button.accessibilityIdentifier = "tasks.panel.dismiss.\(row.task.id)"
            button.setContentHuggingPriority(.required, for: .horizontal)
            line.addArrangedSubview(button)
        }
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        addSubview(line)
        let handler = Closure(open)
        let tap = UITapGestureRecognizer(target: handler, action: #selector(Closure.run))
        objc_setAssociatedObject(self, &Self.tapKey, handler, .OBJC_ASSOCIATION_RETAIN)
        addGestureRecognizer(tap)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            line.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated(unsafe) private static var tapKey = 0
}

private final class Closure: NSObject {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func run() { body() }
}
