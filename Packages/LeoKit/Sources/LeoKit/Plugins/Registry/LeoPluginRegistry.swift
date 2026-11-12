import Foundation

/// Where an installed plugin came from.
public enum LeoPluginSource: Codable, Equatable, Sendable {
    /// Shipped inside the app bundle.
    case bundled
    /// Cloned from an https git URL and pinned to `sha`.
    case git(url: String, ref: String, sha: String)
    /// A local folder registered in place (dev mode).
    case dev(path: String)
}

/// One plugin the user has approved. A record exists only after approval (or,
/// for bundled plugins, from the app itself), so `approvedPermissions` is what
/// the plugin may do, whatever its manifest later asks for.
public struct LeoPluginRecord: Codable, Equatable, Sendable {
    public let id: String
    public var source: LeoPluginSource
    /// The user's switch.
    public var enabled: Bool
    public var approvedPermissions: LeoPluginPermissions
    public var hiddenSections: [String]
    /// Pane ids the user hid from the agent pane (Settings → Plugins).
    public var hiddenPanes: [String] = []
    /// Set when the supervisor disabled the plugin after repeated crashes.
    public var disabledReason: String?
    /// The manifest's name and version when last seen, for lists that don't load the plugin.
    public var name: String
    public var version: String

    private enum CodingKeys: String, CodingKey {
        case id, source, enabled, approvedPermissions, hiddenSections, hiddenPanes, disabledReason, name, version
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decode(LeoPluginSource.self, forKey: .source)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        approvedPermissions = try c.decode(LeoPluginPermissions.self, forKey: .approvedPermissions)
        hiddenSections = try c.decode([String].self, forKey: .hiddenSections)
        // Registries saved before panes existed have no key.
        hiddenPanes = try c.decodeIfPresent([String].self, forKey: .hiddenPanes) ?? []
        disabledReason = try c.decodeIfPresent(String.self, forKey: .disabledReason)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
    }

    public init(
        id: String, source: LeoPluginSource, enabled: Bool, approvedPermissions: LeoPluginPermissions,
        hiddenSections: [String], hiddenPanes: [String] = [], disabledReason: String?, name: String, version: String
    ) {
        self.id = id
        self.source = source
        self.enabled = enabled
        self.approvedPermissions = approvedPermissions
        self.hiddenSections = hiddenSections
        self.hiddenPanes = hiddenPanes
        self.disabledReason = disabledReason
        self.name = name
        self.version = version
    }

    /// Whether the manager should be running it.
    public var isRunnable: Bool { enabled && disabledReason == nil }
}

/// The set of plugins Leo knows: a pure value, persisted by `LeoPluginStore`.
/// It is also the installer's `LeoPluginIDClaimLookup`, so an id stays bound
/// to the source it was first installed from.
public struct LeoPluginRegistry: Codable, Equatable, Sendable, LeoPluginIDClaimLookup {
    public private(set) var records: [LeoPluginRecord] = []

    public init() {}

    public func record(for id: String) -> LeoPluginRecord? { records.first { $0.id == id } }

    public var devFolders: [URL] {
        records.compactMap { record in
            if case .dev(let path) = record.source { URL(fileURLWithPath: path) } else { nil }
        }
    }

    // MARK: Registering

    /// A bundled plugin is enabled and pre-approved for what it ships with, once.
    /// An existing record is never touched: a later, larger manifest is a
    /// permission increase the user must approve, not a silent grant.
    public mutating func registerBundled(_ manifest: LeoPluginManifest) {
        guard record(for: manifest.id) == nil else { return }
        insert(manifest, source: .bundled)
    }

    /// A git plugin the user approved. Replaces a record for the same id.
    public mutating func registerInstalled(_ manifest: LeoPluginManifest, url: String, ref: String, sha: String) {
        insert(manifest, source: .git(url: url, ref: ref, sha: sha))
    }

    /// A local dev folder the user approved.
    public mutating func registerDev(_ manifest: LeoPluginManifest, path: String) {
        insert(manifest, source: .dev(path: path))
    }

    // MARK: Changing

    public mutating func setEnabled(_ id: String, _ enabled: Bool) {
        update(id) {
            $0.enabled = enabled
            if enabled { $0.disabledReason = nil }
        }
    }

    /// Crash-disable: the user's switch stays on, but the plugin won't run until re-enabled.
    public mutating func setDisabled(_ id: String, reason: String) {
        update(id) { $0.disabledReason = reason }
    }

    /// The user approved `permissions` (an install, or an update that asked for more).
    public mutating func approve(_ id: String, permissions: LeoPluginPermissions) {
        update(id) { $0.approvedPermissions = permissions }
    }

    public mutating func setSource(_ id: String, _ source: LeoPluginSource, version: String) {
        update(id) {
            $0.source = source
            $0.version = version
        }
    }

    public mutating func setSection(_ id: String, section: String, hidden: Bool) {
        update(id) {
            var sections = $0.hiddenSections.filter { $0 != section }
            if hidden { sections.append(section) }
            $0.hiddenSections = sections.sorted()
        }
    }

    public mutating func setPane(_ id: String, pane: String, hidden: Bool) {
        update(id) {
            var panes = $0.hiddenPanes.filter { $0 != pane }
            if hidden { panes.append(pane) }
            $0.hiddenPanes = panes.sorted()
        }
    }

    public mutating func remove(_ id: String) {
        records.removeAll { $0.id == id }
    }

    // MARK: Approval

    /// What `new` asks for beyond what the user approved; nil for an unknown id.
    /// An empty diff needs no sheet.
    public func upgradeDiff(id: String, to new: LeoPluginPermissions) -> LeoPluginPermissionDiff? {
        record(for: id).map { LeoPluginPermissionDiff(old: $0.approvedPermissions, new: new) }
    }

    // MARK: Claims

    public func claim(forID id: String) -> LeoPluginIDClaim? {
        guard let record = record(for: id) else { return nil }
        switch record.source {
        case .git(let url, _, _): return .installed(sourceURL: url)
        case .bundled, .dev: return .reserved
        }
    }

    // MARK: Private

    private mutating func insert(_ manifest: LeoPluginManifest, source: LeoPluginSource) {
        let record = LeoPluginRecord(
            id: manifest.id, source: source, enabled: true, approvedPermissions: manifest.permissions,
            hiddenSections: [], disabledReason: nil, name: manifest.name, version: manifest.version)
        records.removeAll { $0.id == manifest.id }
        records.append(record)
        records.sort { $0.id < $1.id }
    }

    private mutating func update(_ id: String, _ change: (inout LeoPluginRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
    }
}
