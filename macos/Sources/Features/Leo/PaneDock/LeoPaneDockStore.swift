import Combine
import CoreGraphics
import Foundation

/// Where Browser and Files dock, and each dock's size (B-439): app-wide,
/// one instance shared by every window, so a move reaches open windows at
/// once. It publishes its own writes: there is no defaults observer, so
/// nothing here can be called back from inside another defaults write.
///
/// `setEdge(_:for:)` is the one way a pane moves: the View menu, a tab's
/// menu, and dragging a tab (B-440) all go through it.
@MainActor final class LeoPaneDockStore {
    enum Keys {
        static func edge(of pane: LeoDockPane) -> String { "leo.paneDock.\(pane.rawValue).edge" }

        static func size(of edge: LeoDockEdge) -> String {
            switch edge {
            case .right: "leo.paneDock.right.width"
            case .below: "leo.paneDock.below.height"
            }
        }
    }

    private let defaults: UserDefaults?
    private let subject: CurrentValueSubject<LeoPaneDockLayout, Never>

    /// `defaults` nil keeps everything in memory (a split built without a
    /// window's session).
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        let layout = LeoDockPane.allCases.reduce(LeoPaneDockLayout()) { layout, pane in
            // A missing or unknown value is the right edge, today's layout.
            let stored = (defaults?.object(forKey: Keys.edge(of: pane)) as? String).flatMap(LeoDockEdge.init(rawValue:))
            return layout.moving(pane, to: stored ?? .right)
        }
        subject = CurrentValueSubject(layout)
    }

    var layout: LeoPaneDockLayout { subject.value }

    /// Each move, sent once the store has it (`layout` reads the new one).
    var changes: AnyPublisher<LeoPaneDockLayout, Never> { subject.dropFirst().eraseToAnyPublisher() }

    func setEdge(_ edge: LeoDockEdge, for pane: LeoDockPane) {
        guard layout.edge(of: pane) != edge else { return }
        defaults?.set(edge.rawValue, forKey: Keys.edge(of: pane))
        subject.value = layout.moving(pane, to: edge)
    }

    /// The size the user last dragged `edge`'s dock to (its width on the
    /// right, its height below); nil until they have.
    func size(of edge: LeoDockEdge) -> CGFloat? {
        if let memory = sizes[edge] { return memory }
        guard let stored = defaults?.object(forKey: Keys.size(of: edge)) as? NSNumber else { return nil }
        let size = CGFloat(stored.doubleValue)
        return size.isFinite && size > 0 ? size : nil
    }

    func setSize(_ size: CGFloat, of edge: LeoDockEdge) {
        guard size.isFinite, size > 0 else { return }
        if let defaults {
            defaults.set(Double(size), forKey: Keys.size(of: edge))
        } else {
            sizes[edge] = size
        }
    }

    /// Sizes for a store without defaults.
    private var sizes: [LeoDockEdge: CGFloat] = [:]
}
