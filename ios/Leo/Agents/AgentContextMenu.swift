import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// The long-press menu for an agent row, shared by the Agents tab and the Chats
/// list: Move To ▸, Copy To ▸ and Duplicate… (B-324), then Appearance… on a
/// daemon that can resolve it. Every action goes through the app store.
enum AgentContextMenu {
    /// Which entries a row offers; pure so the policy is testable.
    struct Offering: Equatable {
        var moveHosts: [String]
        var offersDuplicate: Bool
        var offersAppearance: Bool

        var isEmpty: Bool { !offersDuplicate && !offersAppearance }

        init(canMove: Bool, availability: MoveAvailability, supportsAppearance: Bool) {
            let moves = canMove && availability.offersDuplicate
            moveHosts = moves ? availability.hosts : []
            offersDuplicate = moves
            offersAppearance = supportsAppearance
        }
    }

    @MainActor
    static func offering(for ref: AgentRef, store: StoreOf<AppFeature>) -> Offering {
        let session = store.fleet.sessions[id: ref.daemonID]
        return Offering(
            canMove: session?.agents[id: ref.name]?.canMove == true,
            availability: store.withState { $0.moveAvailability(for: ref.daemonID) },
            supportsAppearance: session?.supportsAppearance == true
        )
    }

    /// Nil when `ref` is not a known agent or has nothing to offer.
    @MainActor
    static func configuration(for ref: AgentRef, store: StoreOf<AppFeature>) -> UIContextMenuConfiguration? {
        guard !offering(for: ref, store: store).isEmpty else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak store] _ in
            guard let store else { return nil }
            return UIMenu(children: elements(for: ref, offering: offering(for: ref, store: store), store: store))
        })
    }

    @MainActor
    static func elements(for ref: AgentRef, offering: Offering, store: StoreOf<AppFeature>) -> [UIMenuElement] {
        var elements: [UIMenuElement] = []
        if offering.offersDuplicate {
            if !offering.moveHosts.isEmpty {
                let move = UIMenu(
                    title: String(localized: "Move To"),
                    image: UIImage(systemName: "arrow.right.circle"),
                    children: offering.moveHosts.map { host in
                        UIAction(title: host) { [weak store] _ in store?.send(.moveRequested(ref, .move(to: host))) }
                    }
                )
                let copy = UIMenu(
                    title: String(localized: "Copy To"),
                    image: UIImage(systemName: "doc.on.doc"),
                    children: offering.moveHosts.map { host in
                        UIAction(title: host) { [weak store] _ in store?.send(.moveRequested(ref, .copy(to: host))) }
                    }
                )
                move.accessibilityIdentifier = "agent.move.to"
                copy.accessibilityIdentifier = "agent.move.copyTo"
                elements += [move, copy]
            }
            let duplicate = UIAction(
                title: String(localized: "Duplicate…"),
                image: UIImage(systemName: "plus.square.on.square")
            ) { [weak store] _ in
                store?.send(.moveRequested(ref, .duplicate))
            }
            duplicate.accessibilityIdentifier = "agent.move.duplicate"
            elements.append(duplicate)
        }
        if offering.offersAppearance {
            let appearance = UIAction(
                title: String(localized: "Appearance…"),
                image: UIImage(systemName: "paintpalette")
            ) { [weak store] _ in
                store?.send(.appearanceRequested(ref))
            }
            appearance.accessibilityIdentifier = "agent.appearance"
            elements.append(appearance)
        }
        return elements
    }
}
