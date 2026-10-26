import LeoFeatures
import LeoKit
import UIKit

/// One row of the Machines list: the symbol column, the name and status
/// line, the address line, an optional failure reason, and the meter line.
/// One layout for every Stats style; only the meter line changes.
struct MachineCellConfiguration: UIContentConfiguration, Equatable {
    var name: String
    var address: String
    var status: String
    var tint: UIColor
    var reason: String?
    var meters: [MachineMeter]?
    var style: LeoStatsStyle

    func makeContentView() -> any UIView & UIContentView { MachineCellContentView(configuration: self) }
    func updated(for state: any UIConfigurationState) -> MachineCellConfiguration { self }
}

extension MachineCellConfiguration {
    init(session: DaemonSession, style: LeoStatsStyle) {
        let connection = session.connection
        let isUnreachable: Bool
        if case .reconnecting = connection { isUnreachable = true } else { isUnreachable = false }
        name = session.daemon.name
        address = connection.isConnected
            ? String(localized: "\(session.daemon.displayHost) · \(LeoAgentCountText.describing(session.agents.count))")
            : session.daemon.displayHost
        status = isUnreachable ? String(localized: "Unreachable") : connection.label
        tint = isUnreachable ? .systemRed : connection.tint
        reason = connection.detail
        meters = style.showsMeters ? session.meters : nil
        self.style = style
    }
}

private final class MachineCellContentView: UIView, UIContentView {
    private let icon = UIImageView()
    private let name = UILabel()
    private let dot = UIView()
    private let status = UILabel()
    private let address = UILabel()
    private let reason = UILabel()
    private let meterLine = MeterLineView()
    private let text = UIStackView()

    /// UIKit sets the configuration again on every cell state change (each
    /// highlight, selection, focus), not only when the data changed. Rebuilding
    /// the meters then restarts their layers inside the state change's
    /// animation, so they flash and the fills jump; an equal one is a no-op.
    var configuration: any UIContentConfiguration {
        didSet {
            guard let new = configuration as? MachineCellConfiguration,
                  new != oldValue as? MachineCellConfiguration else { return }
            apply()
        }
    }

    init(configuration: MachineCellConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        build()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        icon.image = UIImage(systemName: "server.rack")
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)

        name.font = .preferredFont(forTextStyle: .headline)
        name.adjustsFontForContentSizeCategory = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .preferredFont(forTextStyle: .subheadline)
        status.adjustsFontForContentSizeCategory = true
        status.textColor = .secondaryLabel
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
        let statusGroup = UIStackView(arrangedSubviews: [dot, status])
        statusGroup.spacing = 6
        statusGroup.alignment = .center
        let nameLine = UIStackView(arrangedSubviews: [name, UIView(), statusGroup])
        nameLine.spacing = 12
        nameLine.alignment = .firstBaseline

        address.font = .preferredFont(forTextStyle: .subheadline)
        address.adjustsFontForContentSizeCategory = true
        address.textColor = .secondaryLabel
        reason.font = .preferredFont(forTextStyle: .footnote)
        reason.adjustsFontForContentSizeCategory = true
        reason.textColor = .systemRed
        reason.numberOfLines = 0

        text.axis = .vertical
        for view in [nameLine, address, reason, meterLine] { text.addArrangedSubview(view) }
        text.setCustomSpacing(2, after: address)

        let row = UIStackView(arrangedSubviews: [icon, text])
        row.spacing = 12
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 22),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    private func apply() {
        guard let configuration = configuration as? MachineCellConfiguration else { return }
        icon.tintColor = configuration.tint
        name.text = configuration.name
        dot.backgroundColor = configuration.tint
        status.text = configuration.status
        address.text = configuration.address
        reason.text = configuration.reason
        reason.isHidden = configuration.reason == nil
        let gap: CGFloat = configuration.meters == nil ? 0 : 9
        text.setCustomSpacing(reason.isHidden ? gap : 2, after: address)
        text.setCustomSpacing(gap, after: reason)
        if let meters = configuration.meters {
            meterLine.configure(meters: meters, style: configuration.style)
            meterLine.isHidden = false
        } else {
            meterLine.isHidden = true
        }
    }
}
