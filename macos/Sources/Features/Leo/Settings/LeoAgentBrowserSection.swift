import SwiftUI

/// Settings ▸ Machines ▸ Agent browser: the switch for agents' browsers on
/// this Mac, unavailable before macOS 14.
struct LeoAgentBrowserSection: View {
    @ObservedObject var setting: LeoAgentBrowserSetting

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Agent browser").frame(width: 90, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Let agents open and drive a browser on this Mac", isOn: $setting.isOn)
                    .disabled(!setting.isSupported)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var caption: String {
        setting.isSupported
            ? "Turning it off closes every agent's browser; their cookies and logins stay. Stored on this Mac only."
            : "Requires macOS 14."
    }
}
