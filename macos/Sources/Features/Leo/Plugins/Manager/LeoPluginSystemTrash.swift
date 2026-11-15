import Foundation
import LeoKit

/// Moves a plugin folder to the Trash so an uninstall can be undone.
struct LeoPluginSystemTrash: LeoPluginTrashing {
    func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
