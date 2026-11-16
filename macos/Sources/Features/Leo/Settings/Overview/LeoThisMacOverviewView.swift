import AppKit
import LeoKit
import SwiftUI

/// Settings ▸ This Mac: the managed daemon's state and actions, the config
/// file, and the local socket. Reload Config and Restart Daemon… live here
/// because the app can reach This Mac's daemon whenever it is connected.
struct LeoThisMacOverviewView: View {
    @ObservedObject var target: LeoSettingsTargetModel
    @ObservedObject var feed: LeoManagedDaemonFeed
    /// Observed so the badge and socket follow the live connection.
    @ObservedObject var registry: LeoMachineRegistry
    let agentCount: () -> Int
    /// Reveals the config file; the live one asks Finder.
    var revealInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    var body: some View {
        if case .ready(let client) = target.availability, target.selectedHost == .local {
            LeoThisMacOverviewLive(model: target.service(using: client), host: self)
        } else {
            content(service: nil, status: nil)
        }
    }

    fileprivate func content(service: LeoServiceSettingsModel?, status: LeoServiceStatus?) -> some View {
        let overview = LeoThisMacOverview(
            managed: feed.status, presentation: feed.presentation, connection: registry.connectionState(for: .local),
            status: registry.status(for: .local), service: status, agentCount: agentCount(), daemonVersion: target.daemonVersion
        )
        return LeoThisMacOverviewContent(
            overview: overview, service: service, perform: { feed.perform($0) }, reveal: { revealInFinder(URL(fileURLWithPath: $0)) }
        )
    }
}

/// The overview with This Mac's Service model, whose status carries the config path.
private struct LeoThisMacOverviewLive: View {
    @ObservedObject var model: LeoServiceSettingsModel
    let host: LeoThisMacOverviewView

    var body: some View {
        host.content(service: model, status: model.status)
            .task { await model.load() }
    }
}

/// The page itself, from a presentation and the Service model that serves its controls.
struct LeoThisMacOverviewContent: View {
    let overview: LeoThisMacOverview
    let service: LeoServiceSettingsModel?
    let perform: (LeoManagedSettingsAction) -> Void
    let reveal: (String) -> Void

    var body: some View {
        Form {
            Section {
                LeoOverviewHeader(systemImage: "laptopcomputer", name: "This Mac", subtitle: overview.agentCountText) {
                    LeoConnectionBadge(status: overview.status)
                }
                if let reason = overview.reason { LeoOverviewReason(text: reason) }
            }
            Section {
                LabeledContent {
                    if let version = overview.version { Text("leo \(version)").foregroundStyle(.secondary) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(overview.daemon.title)
                        Text(overview.daemon.detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
                actions
                if let path = overview.configPath { configRow(path) }
                if let service { LeoThisMacDaemonControls(model: service) }
            } header: {
                Text("Daemon")
            } footer: {
                if service != nil { Text("Restarting pauses busy agents first. Their tmux sessions keep running.") }
            }
            Section {
                if let socket = overview.socketPath {
                    LabeledContent("Local socket") {
                        Text(socket).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Label("This Mac can’t be removed.", systemImage: "lock.fill").foregroundStyle(.secondary)
            } header: {
                Text("Connection")
            }
        }
        .formStyle(.grouped)
        .modifier(LeoOptionalServiceConfirmations(model: service))
    }

    @ViewBuilder private var actions: some View {
        if !overview.actions.isEmpty {
            HStack {
                Spacer()
                ForEach(overview.actions, id: \.title) { action in
                    Button(action.title) { perform(action) }
                }
            }
        }
    }

    private func configRow(_ path: String) -> some View {
        LabeledContent("Config file") {
            HStack {
                Text(path).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                Button("Show in Finder") { reveal(path) }
            }
        }
    }
}

/// Reload Config and Restart Daemon…, with the Service model's outcome messages.
private struct LeoThisMacDaemonControls: View {
    @ObservedObject var model: LeoServiceSettingsModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack {
                Spacer()
                if model.isRestarting {
                    ProgressView().controlSize(.small)
                    Text(model.isWaitingOnAgents ? "Waiting for busy agents to pause…" : "Waiting for leo to come back…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Reload Config") { Task { await model.reloadConfig() } }
                    .disabled(model.isRestarting || model.isWorking)
                Button("Restart Daemon…") { model.requestRestartDaemon() }
                    .disabled(!model.canRestartDaemon)
            }
            LeoServiceMessages(model: model)
        }
    }
}

/// The Service model's restart alert, when there is a model.
private struct LeoOptionalServiceConfirmations: ViewModifier {
    let model: LeoServiceSettingsModel?

    func body(content: Content) -> some View {
        if let model {
            content.leoServiceConfirmations(model, machine: "This Mac")
        } else {
            content
        }
    }
}
