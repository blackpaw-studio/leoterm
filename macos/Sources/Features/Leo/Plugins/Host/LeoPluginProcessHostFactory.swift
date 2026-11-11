import Foundation
import LeoKit

/// Makes one helper-process connection per call, each with its own launcher
/// pointing at the helper embedded in the app bundle.
struct LeoPluginProcessHostFactory: LeoPluginHostMaking {
    private let launcher: LeoPluginPosixLauncher

    init(launcher: LeoPluginPosixLauncher = .embedded()) {
        self.launcher = launcher
    }

    func makeHost() -> any LeoPluginHosting {
        LeoPluginHostConnection(launcher: launcher)
    }
}
