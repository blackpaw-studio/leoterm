import LeoKit
import SwiftUI

/// The Environments tab: the generic collection pane on the `environments`
/// resource, whose one field is the `env` map (secret variables are listed
/// by name with Replace and Clear, never shown).
struct LeoEnvironmentsSettingsView: View {
    static let tab = LeoSettingsTab.config("environments")

    @ObservedObject var target: LeoSettingsTargetModel

    var body: some View {
        LeoSettingsPaneState(target: target, tab: Self.tab) { client in
            LeoConfigCollectionPane(resource: "environments", target: target, client: client)
        }
    }
}
