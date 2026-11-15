#if DEBUG
import Foundation

// MARK: Leo

/// Debug builds only: forces an update state at launch so the pill can be
/// checked in a window without a real update. Set `LEO_UPDATE_FIXTURE` to an
/// `UpdateSimulator` case name (`happyPath`: "Update Available" after 2 s and
/// it stays; `slowDownload`; `installing`; `notFound`; `error`). Unset, it
/// does nothing; release builds don't contain it.
enum LeoUpdateFixture {
    static let environmentKey = "LEO_UPDATE_FIXTURE"

    static func simulator(named name: String) -> UpdateSimulator? {
        switch name {
        case "happyPath": .happyPath
        case "notFound": .notFound
        case "error": .error
        case "slowDownload": .slowDownload
        case "installing": .installing
        default: nil
        }
    }

    @MainActor
    static func apply(to viewModel: UpdateViewModel, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let name = environment[environmentKey], let simulator = simulator(named: name) else { return }
        simulator.simulate(with: viewModel)
    }
}
#endif
