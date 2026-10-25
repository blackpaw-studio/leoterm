import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// One line of news above a config screen, with the buttons that answer it.
struct ConfigBanner {
    enum Style { case info, warning, error }

    struct Action {
        let title: String
        let handler: () -> Void
    }

    let id: String
    let style: Style
    let text: String
    var actions: [Action] = []
}

/// Stacks banners; an empty list collapses it.
final class ConfigBannerStack: UIStackView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        spacing = 1
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ banners: [ConfigBanner]) {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        banners.map(Self.view(for:)).forEach(addArrangedSubview)
    }

    private static func view(for banner: ConfigBanner) -> UIView {
        let label = UILabel()
        label.text = banner.text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.accessibilityIdentifier = "config.banner.\(banner.id)"

        let buttons = UIStackView(arrangedSubviews: banner.actions.map { action in
            var configuration = UIButton.Configuration.plain()
            configuration.title = action.title
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 12)
            let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action.handler() })
            button.accessibilityIdentifier = "config.banner.\(banner.id).\(action.title)"
            return button
        })
        buttons.spacing = 4
        buttons.isHidden = banner.actions.isEmpty
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.addArrangedSubview(spacer)

        let stack = UIStackView(arrangedSubviews: [label, buttons])
        stack.axis = .vertical
        stack.spacing = 2
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16)
        stack.backgroundColor = background(banner.style)
        return stack
    }

    private static func background(_ style: ConfigBanner.Style) -> UIColor {
        switch style {
        case .info: .secondarySystemFill
        case .warning: .systemOrange.withAlphaComponent(0.18)
        case .error: .systemRed.withAlphaComponent(0.15)
        }
    }
}

/// The banners a collection pane's state calls for, wired to its store.
@MainActor
enum ConfigBanners {
    static func banners(_ store: StoreOf<ConfigCollection>, restart: StoreOf<MachineRestart>? = nil) -> [ConfigBanner] {
        let state = store.state
        let core = state.core
        var banners: [ConfigBanner] = []
        if let restart, restart.isRestarting {
            let text = restart.isWaitingOnAgents ? MachineRestart.State.waitingOnAgentsText : "Restarting leo on \(restart.machine)…"
            banners.append(ConfigBanner(id: "restarting", style: .info, text: text))
        }
        if !state.isMachineConnected {
            let text = core.isDirty ? "Disconnected — your edits are kept." : "Disconnected."
            banners.append(ConfigBanner(id: "disconnected", style: .warning, text: text))
        }
        if core.conflict != nil {
            banners.append(ConfigBanner(
                id: "conflict", style: .warning, text: "This changed on the machine since you opened it.",
                actions: [
                    .init(title: "Reload") { store.send(.reloadTapped) },
                    .init(title: "Overwrite") { store.send(.overwriteTapped) },
                ]
            ))
        }
        if let restart = core.restartPrompt {
            var actions: [ConfigBanner.Action] = []
            if restart.service { actions.append(.init(title: "Restart leo") { store.send(.restartBannerTapped(.daemon)) }) }
            if restart.agents { actions.append(.init(title: "Restart Agents") { store.send(.restartBannerTapped(.agents)) }) }
            actions.append(.init(title: "Later") { store.send(.dismissRestartBanner) })
            banners.append(ConfigBanner(id: "restart", style: .info, text: restartText(restart), actions: actions))
        }
        if let warning = core.warning {
            banners.append(ConfigBanner(
                id: "warning", style: .warning, text: warning, actions: [.init(title: "Dismiss") { store.send(.dismissErrorTapped) }]
            ))
        }
        if let message = core.errorMessage {
            banners.append(ConfigBanner(
                id: "error", style: .error, text: message, actions: [.init(title: "Dismiss") { store.send(.dismissErrorTapped) }]
            ))
        }
        return banners
    }

    private static func restartText(_ restart: LeoConfigRestartRequired) -> String {
        switch (restart.service, restart.agents) {
        case (true, true): "Saved. Restart leo and its agents for this to take effect."
        case (true, false): "Saved. Restart leo for this to take effect."
        default: "Saved. Restart the agents for this to take effect."
        }
    }
}
