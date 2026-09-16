import Combine
import AppKit
import Foundation

struct LeoWindowVisibilityState: Equatable {
    enum Event {
        case occlusionChanged(isVisible: Bool)
        case miniaturized
        case deminiaturized
    }

    private(set) var isOccluded = false
    private(set) var isMiniaturized = false

    mutating func reduce(_ event: Event) {
        switch event {
        case .occlusionChanged(let isVisible): isOccluded = !isVisible
        case .miniaturized: isMiniaturized = true
        case .deminiaturized: isMiniaturized = false
        }
    }
}

@MainActor final class LeoWindowSession: ObservableObject {
    @Published var isSidebarVisible: Bool { didSet { changed() } }
    @Published private(set) var preferredWidth: CGFloat
    @Published var windowIsOccluded = false { didSet { changed() } }
    @Published var windowIsMiniaturized = false { didSet { changed() } }
    var displayedWidth: CGFloat { min(max(preferredWidth, 200), 420) }

    private let defaults: UserDefaults
    private let onPollabilityChanged: () -> Void
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var visibility = LeoWindowVisibilityState()

    init(window: NSWindow? = nil, defaults: UserDefaults = .standard, onPollabilityChanged: @escaping () -> Void = {}) {
        self.defaults = defaults
        self.onPollabilityChanged = onPollabilityChanged
        self.window = window
        isSidebarVisible = defaults.object(forKey: "leo.sidebarVisible") as? Bool ?? true
        preferredWidth = (defaults.object(forKey: "leo.sidebarWidth") as? NSNumber).map { CGFloat($0.doubleValue) } ?? 260
        observeWindow()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    var isPollable: Bool { isSidebarVisible && !windowIsOccluded && !windowIsMiniaturized }

    func setSidebarVisible(_ visible: Bool) {
        isSidebarVisible = visible
        defaults.set(visible, forKey: "leo.sidebarVisible")
    }

    func setPreferredWidth(_ width: CGFloat) {
        preferredWidth = width
        defaults.set(Double(width), forKey: "leo.sidebarWidth")
    }

    private func observeWindow() {
        guard let window else { return }
        apply(.occlusionChanged(isVisible: window.occlusionState.contains(.visible)))
        if window.isMiniaturized { apply(.miniaturized) }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.apply(.occlusionChanged(isVisible: window.occlusionState.contains(.visible))) }
            },
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(.miniaturized) }
            },
            center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(.deminiaturized) }
            },
        ]
    }

    private func apply(_ event: LeoWindowVisibilityState.Event) {
        visibility.reduce(event)
        windowIsOccluded = visibility.isOccluded
        windowIsMiniaturized = visibility.isMiniaturized
    }

    private func changed() { onPollabilityChanged() }
}

@MainActor final class LeoWindowSessionRegistry {
    private final class Entry { weak var session: LeoWindowSession?; init(_ session: LeoWindowSession) { self.session = session } }
    private var entries: [ObjectIdentifier: Entry] = [:]
    var pollabilityChanged: (Bool) -> Void = { _ in }

    func makeSession(window: NSWindow? = nil, defaults: UserDefaults = .standard) -> LeoWindowSession {
        let session = LeoWindowSession(window: window, defaults: defaults) { [weak self] in self?.report() }
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
