import LeoKit
import SwiftUI

/// What a plugin is, where it came from and what it asks for, before anything
/// runs. An update shows only the permissions that are new.
struct LeoPluginApprovalSheet: View {
    let request: LeoPluginApprovalRequest
    let finish: (Bool?) -> Void

    private var title: String {
        if request.isUpdate { return "Update “\(request.name)”?" }
        return request.isDev ? "Load “\(request.name)”?" : "Install “\(request.name)”?"
    }

    private var confirmTitle: String {
        if request.isUpdate { return "Update" }
        return request.isDev ? "Load" : "Install"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(request.id) · \(request.version)").font(.callout.monospaced())
                Text(request.sourceDescription).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let sha = request.sha { Text("Commit \(sha)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Divider()
            Text(request.isUpdate ? "This version also wants to:" : "This plugin can:").font(.subheadline)
            if request.permissionLines.isEmpty {
                Text("Nothing beyond drawing its own views.").foregroundStyle(.secondary)
            } else {
                ForEach(request.permissionLines, id: \.self) {
                    Label($0, systemImage: "checkmark.shield").fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Nothing runs until you approve.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button(confirmTitle) { finish(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}

extension LeoPluginSheetPresenter {
    /// True if the person approved.
    @MainActor func approve(_ request: LeoPluginApprovalRequest) async -> Bool {
        let result: Bool? = await presentCancellable { finish in LeoPluginApprovalSheet(request: request, finish: finish) }
        return result == true
    }
}
