import Combine
import Foundation
import LeoKit

/// The Daemon pane: the service (status, actions, log), the web UI form, the
/// remote client form and the remote hosts, behind one picker. The service's
/// model belongs to the target, not to this one. Each keeps its own draft, so
/// switching between them never loses an edit, and the tab answers the
/// Settings window's unsaved-changes and reconnect hooks for all three.
///
/// The client's `default_host` picks from the hosts, and follows them as they
/// are added and deleted. The daemon doesn't treat it as a foreign key:
/// deleting the default host leaves the setting as it was. Those rules, and
/// the section order, are LeoKit's (`LeoDaemonPane`), shared with iOS.
@MainActor final class LeoDaemonSettingsModel: ObservableObject, LeoSettingsPane {
    typealias Section = LeoDaemonPane.Section

    let web: LeoConfigSingletonModel
    let client: LeoConfigSingletonModel
    let hosts: LeoConfigCollectionModel
    @Published var section = Section.service

    private var subscriptions: Set<AnyCancellable> = []

    init(client daemon: any LeoConfigClient, revisions: LeoConfigRevisionTracker, machineHost: String? = nil) {
        web = LeoConfigSingletonModel(resource: LeoDaemonPane.webKey, client: daemon, revisions: revisions, machineHost: machineHost)
        client = LeoConfigSingletonModel(
            resource: LeoDaemonPane.clientKey, client: daemon, revisions: revisions, machineHost: machineHost,
            resourceTransform: LeoDaemonPane.clientResource
        )
        hosts = LeoConfigCollectionModel(resource: LeoDaemonPane.hostsKey, client: daemon, revisions: revisions, machineHost: machineHost)
        let client = client
        hosts.$state.map(\.items).removeDuplicates()
            .sink { items in client.setReferences(LeoDaemonPane.hostReferences(items)) }
            .store(in: &subscriptions)
    }

    func load() async {
        await hosts.load()
        await web.load()
        await client.load()
    }

    /// Whether the service log tail polls: only while it is on screen, which
    /// is the Daemon pane selected on the Service section.
    func isLogVisible(paneSelected: Bool) -> Bool {
        paneSelected && section == .service
    }

    // MARK: LeoSettingsPane

    var hasUnsavedChanges: Bool {
        web.hasUnsavedChanges || client.hasUnsavedChanges || hosts.hasUnsavedChanges
    }

    func discardChanges() {
        web.discardChanges()
        client.discardChanges()
        hosts.discardChanges()
    }

    func reload(using daemon: any LeoConfigClient) async {
        await hosts.reload(using: daemon)
        await web.reload(using: daemon)
        await client.reload(using: daemon)
    }

    // MARK: Hosts

    /// What deleting `host` also means, when it is more than removing the
    /// host: the client's default host is left naming it.
    func deleteNote(forHost host: String) -> String? {
        LeoDaemonPane.deleteNote(forHost: host, client: client.draft)
    }
}
