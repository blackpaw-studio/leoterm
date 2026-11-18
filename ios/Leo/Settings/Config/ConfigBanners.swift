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
        // An empty stack still takes part in its parent's layout; on iOS 26.5 it
        // won the spare height and left the screen below it with none.
        isHidden = banners.isEmpty
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

/// What a config screen's state says, for its banners.
struct ConfigBannerInput {
    var isMachineConnected = true
    var isDirty = false
    var hasConflict = false
    var restartPrompt: LeoConfigRestartRequired?
    var warning: String?
    var errorMessage: String?
}

/// What a config screen's banner buttons send.
struct ConfigBannerActions {
    var reload: () -> Void = {}
    var overwrite: () -> Void = {}
    var restart: (MachineRestart.Kind) -> Void = { _ in }
    var dismissRestart: () -> Void = {}
    var dismissError: () -> Void = {}
}

/// The banners a config screen's state calls for, wired to its store.
@MainActor
enum ConfigBanners {
    static func banners(_ store: StoreOf<ConfigCollection>, restart: StoreOf<MachineRestart>? = nil) -> [ConfigBanner] {
        let core = store.core
        let input = ConfigBannerInput(
            isMachineConnected: store.isMachineConnected, isDirty: core.isDirty, hasConflict: core.conflict != nil,
            restartPrompt: core.restartPrompt, warning: core.warning, errorMessage: core.errorMessage
        )
        return banners(input, restart: restart, actions: ConfigBannerActions(
            reload: { store.send(.reloadTapped) }, overwrite: { store.send(.overwriteTapped) },
            restart: { store.send(.restartBannerTapped($0)) }, dismissRestart: { store.send(.dismissRestartBanner) },
            dismissError: { store.send(.dismissErrorTapped) }
        ))
    }

    static func banners(_ store: StoreOf<ConfigSingleton>, restart: StoreOf<MachineRestart>? = nil) -> [ConfigBanner] {
        let core = store.core
        let input = ConfigBannerInput(
            isMachineConnected: store.isMachineConnected, isDirty: core.isDirty, hasConflict: core.conflict != nil,
            restartPrompt: core.restartPrompt, warning: core.warning, errorMessage: core.errorMessage
        )
        return banners(input, restart: restart, actions: ConfigBannerActions(
            reload: { store.send(.reloadTapped) }, overwrite: { store.send(.overwriteTapped) },
            restart: { store.send(.restartBannerTapped($0)) }, dismissRestart: { store.send(.dismissRestartBanner) },
            dismissError: { store.send(.dismissErrorTapped) }
        ))
    }

    static func banners(_ store: StoreOf<DelegationSettings>, restart: StoreOf<MachineRestart>? = nil) -> [ConfigBanner] {
        let core = store.core
        let input = ConfigBannerInput(
            isMachineConnected: store.isMachineConnected, isDirty: core.hasUnsavedChanges, hasConflict: core.conflict != nil,
            restartPrompt: core.restartPrompt, warning: core.warning, errorMessage: core.errorMessage
        )
        return banners(input, restart: restart, actions: ConfigBannerActions(
            reload: { store.send(.reloadTapped) }, overwrite: { store.send(.overwriteTapped) },
            restart: { store.send(.restartBannerTapped($0)) }, dismissRestart: { store.send(.dismissRestartBanner) },
            dismissError: { store.send(.dismissErrorTapped) }
        ))
    }

    static func banners(_ input: ConfigBannerInput, restart: StoreOf<MachineRestart>?, actions: ConfigBannerActions) -> [ConfigBanner] {
        var banners: [ConfigBanner] = []
        if let restart, restart.isRestarting {
            let text = restart.isWaitingOnAgents ? MachineRestart.State.waitingOnAgentsText : "Restarting leo on \(restart.machine)…"
            banners.append(ConfigBanner(id: "restarting", style: .info, text: text))
        }
        if !input.isMachineConnected {
            let text = input.isDirty ? "Disconnected — your edits are kept." : "Disconnected."
            banners.append(ConfigBanner(id: "disconnected", style: .warning, text: text))
        }
        if input.hasConflict {
            banners.append(ConfigBanner(
                id: "conflict", style: .warning, text: "This changed on the machine since you opened it.",
                actions: [.init(title: "Reload", handler: actions.reload), .init(title: "Overwrite", handler: actions.overwrite)]
            ))
        }
        if let restart = input.restartPrompt {
            var buttons: [ConfigBanner.Action] = []
            if restart.service { buttons.append(.init(title: "Restart leo") { actions.restart(.daemon) }) }
            if restart.agents { buttons.append(.init(title: "Restart Agents") { actions.restart(.agents) }) }
            buttons.append(.init(title: "Later", handler: actions.dismissRestart))
            banners.append(ConfigBanner(id: "restart", style: .info, text: restartText(restart), actions: buttons))
        }
        if let warning = input.warning {
            banners.append(ConfigBanner(id: "warning", style: .warning, text: warning, actions: [.init(title: "Dismiss", handler: actions.dismissError)]))
        }
        if let message = input.errorMessage {
            banners.append(ConfigBanner(id: "error", style: .error, text: message, actions: [.init(title: "Dismiss", handler: actions.dismissError)]))
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
