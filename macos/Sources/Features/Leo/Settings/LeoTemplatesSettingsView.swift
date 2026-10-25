import LeoKit
import SwiftUI

/// The Templates tab: the generic collection pane on the `templates` resource.
struct LeoTemplatesSettingsView: View {
    static let tab = LeoSettingsTab.config("templates")

    @ObservedObject var target: LeoSettingsTargetModel

    var body: some View {
        LeoSettingsPaneState(target: target, tab: Self.tab) { client in
            LeoConfigCollectionPane(resource: "templates", target: target, client: client)
        }
    }
}
