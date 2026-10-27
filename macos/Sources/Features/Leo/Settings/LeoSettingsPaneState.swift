import LeoKit
import SwiftUI

/// What a config pane shows in place of its form when the selected machine
/// can't be edited: connecting, disconnected (with Reconnect) or too old. The
/// form appears for a machine that is ready and is rebuilt only when the
/// machine changes. While the same machine reconnects, a pane with unsaved
/// edits stays mounted under a banner (its model reloads on return), so a
/// tunnel blip never drops a draft.
struct LeoSettingsPaneState<Content: View>: View {
    @ObservedObject var target: LeoSettingsTargetModel
    let tab: LeoSettingsTab
    @ViewBuilder let content: (any LeoConfigClient) -> Content

    var body: some View {
        if let client = target.retainedClient(for: tab) {
            // One structure for ready and reconnecting alike: the content keeps
            // its place, and so the state its view owns, while the banner comes and goes.
            VStack(spacing: 0) {
                if !isReady {
                    LeoReconnectingBanner(
                        machine: SpawnMachineOption.title(for: target.selectedHost), isLoading: target.isLoading, reconnect: target.reconnect
                    )
                }
                content(client).id(target.machineEpoch).disabled(!isReady)
            }
        } else {
            notice
        }
    }

    private var isReady: Bool {
        if case .ready = target.availability { return true }
        return false
    }

    @ViewBuilder private var notice: some View {
        switch target.availability {
        case .loading:
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            EmptyView()
        case .disconnected(let status):
            LeoDisconnectedPaneNotice(
                machine: SpawnMachineOption.title(for: target.selectedHost), status: status, reconnect: target.reconnect
            )
        case .tooOld(let info):
            LeoTooOldPaneNotice(machine: SpawnMachineOption.title(for: target.selectedHost), running: info?.version)
        }
    }
}

/// Shown over a mounted pane whose machine is reconnecting: the edits are kept
/// and saving waits for the connection.
struct LeoReconnectingBanner: View {
    let machine: String
    let isLoading: Bool
    let reconnect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(isLoading ? "Reconnecting to \(machine)…" : "\(machine) is disconnected. Your edits are kept.")
            Spacer()
            if !isLoading { Button("Reconnect", action: reconnect) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}

/// Machines-style status for a machine that isn't connected, with Reconnect.
struct LeoDisconnectedPaneNotice: View {
    let machine: String
    let status: LeoMachineStatus?
    let reconnect: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                LeoStatusDot(status: status)
                Text(headline).font(.headline)
            }
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if canReconnect {
                Button("Reconnect", action: reconnect)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var canReconnect: Bool {
        switch status {
        case .failed?, nil: true
        case .connecting?, .connected?, .disabled?: false
        }
    }

    private var headline: String {
        switch status {
        case .failed?: "\(machine) is unreachable"
        case .connecting?, .connected?: "Connecting to \(machine)…"
        case .disabled?: "\(machine) is turned off"
        case nil: "\(machine) isn’t connected"
        }
    }

    private var detail: String {
        switch status {
        case .failed(let message)?: message
        case .connecting?, .connected?: "Settings appear once the connection is up."
        case .disabled?: "Turn it on in Machines to edit its settings."
        case nil: "Leo can’t edit settings on a machine it isn’t connected to."
        }
    }
}

/// A daemon that doesn't serve the config API: a notice, never a half form.
struct LeoTooOldPaneNotice: View {
    let machine: String
    let running: String?
    /// A pane that needs more than the config API says what it needs.
    var customHeadline: String?
    var customDetail: String?

    init(machine: String, running: String?, headline: String? = nil, detail: String? = nil) {
        self.machine = machine
        self.running = running
        customHeadline = headline
        customDetail = detail
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.up.circle").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(headline).font(.headline)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        if let customHeadline { return customHeadline }
        return LeoConfigAPI.minimumVersion.map { "Requires leo ≥ \($0.major).\($0.minor).\($0.patch)" } ?? "Update leo on \(machine)"
    }

    private var detail: String {
        let current = running.map { " It is running leo \($0)." } ?? ""
        return (customDetail ?? "\(machine)’s leo can’t edit its settings from the app yet.") + current
    }
}
