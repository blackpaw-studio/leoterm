import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// The Delegation screen's rows, in the Mac pane's words.
@MainActor
enum DelegationCells {
    typealias Item = DelegationViewController.Item

    static func header(_ section: DelegationViewController.Section) -> String? {
        switch section {
        case .main, .web: nil
        case .profiles: String(localized: "Profiles")
        case .roles: String(localized: "Roles")
        case .warnings: String(localized: "Warnings")
        case .consults: String(localized: "Recent role dispatches")
        }
    }

    static func configure(_ cell: UICollectionViewListCell, item: Item, store: StoreOf<DelegationSettings>) {
        let core = store.core
        var content = UIListContentConfiguration.subtitleCell()
        content.secondaryTextProperties.color = .secondaryLabel
        cell.accessories = []
        cell.accessibilityIdentifier = nil
        switch item {
        case .loading:
            content.text = String(localized: "Loading…")
            content.textProperties.color = .secondaryLabel
        case .failed(let message):
            content.text = message
            content.textProperties.color = .systemRed
            cell.accessibilityIdentifier = "delegation.failed"
        case .retry:
            content.text = String(localized: "Try Again")
            content.textProperties.color = cell.tintColor
            cell.accessibilityIdentifier = "delegation.retry"
        case .notConfigured:
            content.text = String(localized: "Delegation isn’t configured on \(store.daemon.name)")
            content.secondaryText = String(
                localized: "Add a delegation: block to leo.yaml there and it appears here. Roles and profiles can be edited once it exists."
            )
            cell.accessibilityIdentifier = "delegation.notConfigured"
        case .enabled:
            content.text = String(localized: "Delegation")
            cell.accessories = [.customView(configuration: .init(customView: enabledSwitch(store), placement: .trailing()))]
            cell.accessibilityIdentifier = "delegation.enabled"
        case .hiddenAgents:
            content.text = String(localized: "Hidden native agents")
            content.secondaryText = core.hiddenAgentNames.isEmpty ? String(localized: "None") : core.hiddenAgentNames.joined(separator: ", ")
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityIdentifier = "delegation.hiddenAgents"
        default:
            configureList(cell, &content, item: item, store: store)
        }
        cell.contentConfiguration = content
    }

    private static func configureList(
        _ cell: UICollectionViewListCell, _ content: inout UIListContentConfiguration, item: Item, store: StoreOf<DelegationSettings>
    ) {
        let core = store.core
        switch item {
        case .profile(let name):
            let count = core.matrix.routedRoleCount(in: name)
            content.text = name
            content.secondaryText = count == 1 ? String(localized: "1 role") : String(localized: "\(count) roles")
            let isActive = core.matrix.activeProfile?.name == name
            cell.accessories = (isActive ? [.label(text: String(localized: "Active"))] : []) + [.disclosureIndicator()]
            cell.accessibilityIdentifier = "delegation.profile.\(name)"
        case .addProfile:
            action(&content, String(localized: "Add Profile…"), enabled: core.canRestructure, cell: cell)
            cell.accessibilityIdentifier = "delegation.addProfile"
        case .role(let name):
            let role = core.matrix.rows.first { $0.role.name == name }?.role
            content.text = name
            if role?.declared == false {
                content.secondaryText = String(localized: "Undeclared: routed by a profile only")
                content.secondaryTextProperties.color = .systemOrange
            } else {
                content.secondaryText = role?.useFor.isEmpty == false ? role?.useFor : String(localized: "No description")
                cell.accessories = [.disclosureIndicator()]
            }
            cell.accessibilityIdentifier = "delegation.role.\(name)"
        case .addRole:
            action(&content, String(localized: "Add Role…"), enabled: core.canRestructure && !core.templates.isEmpty, cell: cell)
            if core.templates.isEmpty { content.secondaryText = String(localized: "Add a template first") }
            cell.accessibilityIdentifier = "delegation.addRole"
        case .warning(let text):
            content.text = text
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemOrange
        case .consult(let id):
            configureConsult(&content, core.recentConsults.first { $0.id == id })
        case .web:
            content.text = String(localized: "Edit in the web UI")
            content.textProperties.color = cell.tintColor
            cell.accessibilityIdentifier = "delegation.web"
        default:
            break
        }
    }

    private static func action(_ content: inout UIListContentConfiguration, _ title: String, enabled: Bool, cell: UICollectionViewListCell) {
        content.text = title
        content.image = UIImage(systemName: "plus")
        content.textProperties.color = enabled ? cell.tintColor : .tertiaryLabel
        content.imageProperties.tintColor = enabled ? cell.tintColor : .tertiaryLabel
    }

    private static func configureConsult(_ content: inout UIListContentConfiguration, _ consult: LeoDelegationConsult?) {
        guard let consult else { return }
        let target = [consult.template, consult.model, consult.effort].filter { !$0.isEmpty }.joined(separator: " · ")
        content.text = target.isEmpty ? consult.role : "\(consult.role) → \(target)"
        let when = consult.startedAt.map { $0.formatted(.relative(presentation: .named)) }
        content.secondaryText = [consult.profile, consult.status, when].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func enabledSwitch(_ store: StoreOf<DelegationSettings>) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = store.core.displayedEnabled
        toggle.isEnabled = store.core.canWrite
        toggle.accessibilityIdentifier = "delegation.enabled.switch"
        toggle.addAction(UIAction { [weak toggle] _ in
            guard let toggle else { return }
            store.send(.enabledToggled(toggle.isOn))
        }, for: .valueChanged)
        return toggle
    }
}
