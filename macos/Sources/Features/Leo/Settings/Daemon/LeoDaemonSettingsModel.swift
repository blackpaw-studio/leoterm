import Combine
import Foundation
import LeoKit

/// The Daemon tab: the web UI form, the remote client form and the remote
/// hosts, three resources behind one tab. Each keeps its own draft, so
/// switching between them never loses an edit, and the tab answers the
/// Settings window's unsaved-changes and reconnect hooks for all three.
///
/// The client's `default_host` picks from the hosts, and follows them as they
/// are added and deleted. The daemon doesn't treat it as a foreign key:
/// deleting the default host leaves the setting as it was.
@MainActor final class LeoDaemonSettingsModel: ObservableObject, LeoSettingsPane {
    enum Section: CaseIterable, Hashable {
        case web, client, hosts
    }

    static let hostsKey = "hosts"
    static let defaultHostKey = "default_host"

    let web: LeoConfigSingletonModel
    let client: LeoConfigSingletonModel
    let hosts: LeoConfigCollectionModel
    @Published var section = Section.web

    private var subscriptions: Set<AnyCancellable> = []

    init(client daemon: any LeoConfigClient, revisions: LeoConfigRevisionTracker, machineHost: String? = nil) {
        web = LeoConfigSingletonModel(resource: "web", client: daemon, revisions: revisions, machineHost: machineHost)
        client = LeoConfigSingletonModel(
            resource: "client", client: daemon, revisions: revisions, machineHost: machineHost,
            resourceTransform: { $0.referencing(Self.defaultHostKey, to: Self.hostsKey, emptyLabel: "None") }
        )
        hosts = LeoConfigCollectionModel(resource: Self.hostsKey, client: daemon, revisions: revisions, machineHost: machineHost)
        let client = client
        hosts.$state.map(\.items).removeDuplicates()
            .sink { items in client.setReferences([Self.hostsKey: items.map(\.name)]) }
            .store(in: &subscriptions)
    }

    func load() async {
        await hosts.load()
        await web.load()
        await client.load()
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
        guard client.draft?.document.values[Self.defaultHostKey]?.stringValue == host else { return nil }
        return "It is the default host. The default host setting stays set to it until you change it."
    }
}
