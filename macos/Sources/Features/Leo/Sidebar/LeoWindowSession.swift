import Combine
import Foundation

@MainActor final class LeoWindowSession: ObservableObject {
    @Published var isSidebarVisible: Bool { didSet { changed() } }
    @Published private(set) var preferredWidth: CGFloat
    @Published var windowIsOccluded = false { didSet { changed() } }
    @Published var windowIsMiniaturized = false { didSet { changed() } }
    var displayedWidth: CGFloat { min(max(preferredWidth, 200), 420) }

    private let defaults: UserDefaults
    private let onPollabilityChanged: () -> Void

    init(defaults: UserDefaults = .standard, onPollabilityChanged: @escaping () -> Void = {}) {
        self.defaults = defaults
        self.onPollabilityChanged = onPollabilityChanged
        isSidebarVisible = defaults.object(forKey: "leo.sidebarVisible") as? Bool ?? true
        preferredWidth = (defaults.object(forKey: "leo.sidebarWidth") as? NSNumber).map { CGFloat($0.doubleValue) } ?? 260
    }

    var isPollable: Bool { isSidebarVisible && !windowIsOccluded && !windowIsMiniaturized }

    func setSidebarVisible(_ visible: Bool) {
        isSidebarVisible = visible
        defaults.set(visible, forKey: "leo.sidebarVisible")
    }

    func setPreferredWidth(_ width: CGFloat) {
        preferredWidth = width
        defaults.set(Double(width), forKey: "leo.sidebarWidth")
    }

    private func changed() { onPollabilityChanged() }
}

@MainActor final class LeoWindowSessionRegistry {
    private final class Entry { weak var session: LeoWindowSession?; init(_ session: LeoWindowSession) { self.session = session } }
    private var entries: [ObjectIdentifier: Entry] = [:]
    var pollabilityChanged: (Bool) -> Void = { _ in }

    func makeSession(defaults: UserDefaults = .standard) -> LeoWindowSession {
        let session = LeoWindowSession(defaults: defaults) { [weak self] in self?.report() }
        entries[ObjectIdentifier(session)] = Entry(session)
        report()
        return session
    }

    var hasPollableSidebar: Bool {
        entries.values.contains { $0.session?.isPollable == true }
    }

    private func report() {
        entries = entries.filter { $0.value.session != nil }
        pollabilityChanged(hasPollableSidebar)
    }
}
