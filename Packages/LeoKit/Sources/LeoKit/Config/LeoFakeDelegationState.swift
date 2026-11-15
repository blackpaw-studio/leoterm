import Foundation

/// A delegation write the fake received, for assertions in model tests.
public enum LeoFakeDelegationWrite: Equatable, Sendable {
    case cell(profile: String, role: String, target: LeoDelegationTarget)
    case useFor(role: String, text: String)
    case active(String)
    case enabled(Bool)
    case hideAgents([String])
    case addRole(name: String, template: String)
    case renameRole(String, to: String)
    case deleteRole(String)
    case addProfile(String)
    case renameProfile(String, to: String)
    case duplicateProfile(String, as: String)
    case deleteProfile(String)
}

/// The fake daemon's `delegation:` block, with the rules the daemon's
/// mutators enforce. Its templates are fixed at the seed.
public struct LeoFakeDelegationState: Sendable {
    struct Profile: Sendable {
        var description: String
        var cells: [String: LeoDelegationTarget]
    }

    static let defaultHiddenAgents = ["implementer", "implementer-hard", "code-reviewer", "Explore", "Plan", "general-purpose"]
    static let efforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    var enabled: Bool
    var activeProfile: String
    /// Nil is the daemon's built-in list.
    var hiddenAgents: [String]?
    /// Declared roles and their `use_for`; empty means no `delegation.roles` block.
    var declared: [String: String]
    var profiles: [String: Profile]
    let templates: [LeoDelegationTemplate]
    var warnings: [String]
    var consults: [LeoDelegationConsult]

    init(_ document: LeoDelegationDocument) {
        enabled = document.enabled
        activeProfile = document.activeProfile
        hiddenAgents = document.hideNativeAgentsIsDefault ? nil : document.hideNativeAgents
        declared = Dictionary(document.roles.filter(\.declared).map { ($0.name, $0.useFor) }, uniquingKeysWith: { first, _ in first })
        profiles = Dictionary(
            document.profiles.map { ($0.name, Profile(description: $0.description, cells: $0.roles.mapValues(\.target))) },
            uniquingKeysWith: { first, _ in first }
        )
        templates = document.templates
        warnings = document.warnings
        consults = document.recentConsults
    }

    var roleNames: [String] {
        Set(declared.keys).union(profiles.values.flatMap { $0.cells.keys }).sorted()
    }

    func inheritedModel(of template: String) -> String {
        templates.first { $0.name == template }?.model ?? ""
    }

    func document(revision: String) -> LeoDelegationDocument {
        LeoDelegationDocument(
            revision: revision, configured: true, enabled: enabled, activeProfile: activeProfile,
            hideNativeAgents: hiddenAgents ?? Self.defaultHiddenAgents, hideNativeAgentsIsDefault: hiddenAgents == nil,
            templates: templates,
            roles: roleNames.map { LeoDelegationRole(name: $0, useFor: declared[$0] ?? "", declared: declared[$0] != nil) },
            profiles: profiles.keys.sorted().map { name in
                let profile = profiles[name] ?? Profile(description: "", cells: [:])
                return LeoDelegationProfile(
                    name: name, description: profile.description, active: name == activeProfile,
                    roles: profile.cells.mapValues {
                        LeoDelegationCell(template: $0.template, model: $0.model, effort: $0.effort, inheritedModel: inheritedModel(of: $0.template))
                    }
                )
            },
            warnings: warnings, recentConsults: consults
        )
    }

    func preview(of target: String) throws -> LeoDelegationPreview {
        guard let next = profiles[target] else { throw Self.notFound("profile \"\(target)\" not found") }
        let current = profiles[activeProfile]?.cells ?? [:]
        let changes = Set(current.keys).union(next.cells.keys).sorted().compactMap { role -> LeoDelegationPreview.Change? in
            switch (current[role], next.cells[role]) {
            case (nil, let after?): return .init(role: role, kind: .added, before: LeoDelegationTarget(), after: after)
            case (let before?, nil): return .init(role: role, kind: .removed, before: before, after: LeoDelegationTarget())
            case (let before?, let after?) where before != after: return .init(role: role, kind: .changed, before: before, after: after)
            default: return nil
            }
        }
        return LeoDelegationPreview(profile: target, changes: changes, missing: declared.keys.filter { next.cells[$0] == nil }.sorted())
    }

    // MARK: mutators (the daemon's, `internal/web/config_delegation.go`)

    static func notFound(_ message: String) -> LeoDaemonError {
        LeoDaemonError.daemon(code: "not_found", message: message, matches: [])
    }

    static func invalid(_ field: String, _ message: String) -> LeoConfigError {
        LeoConfigError.invalid([LeoConfigFieldError(field: field, message: message)])
    }

    mutating func setCell(profile: String, role: String, target: LeoDelegationTarget) throws {
        guard var entry = profiles[profile] else { throw Self.notFound("profile \"\(profile)\" not found") }
        if target.template.isEmpty {
            entry.cells[role] = nil
        } else {
            guard templates.contains(where: { $0.name == target.template }) else {
                throw Self.invalid("template", "template \"\(target.template)\" not found")
            }
            guard target.effort.isEmpty || Self.efforts.contains(target.effort) else {
                throw Self.invalid(
                    "effort", "delegation.profiles.\(profile).roles.\(role).effort \"\(target.effort)\" is not valid (use low, medium, high, xhigh, or max)"
                )
            }
            entry.cells[role] = target
        }
        profiles[profile] = entry
    }

    mutating func setUseFor(role: String, text: String) throws {
        guard declared[role] != nil else { throw Self.notFound("role \"\(role)\" not found") }
        declared[role] = text
    }

    mutating func setActive(_ name: String) throws {
        guard profiles[name] != nil else { throw Self.notFound("profile \"\(name)\" not found") }
        activeProfile = name
    }

    mutating func addRole(name: String, template: String, nameError: (String) -> String?) throws {
        if let message = nameError(name) { throw Self.invalid("name", message) }
        if roleNames.contains(name) { throw Self.invalid("name", "role \"\(name)\" already exists") }
        guard templates.contains(where: { $0.name == template }) else { throw Self.invalid("template", "template \"\(template)\" not found") }
        if declared.isEmpty {
            declared = Dictionary(uniqueKeysWithValues: (profiles[activeProfile]?.cells.keys.map { $0 } ?? []).map { ($0, "") })
        }
        declared[name] = ""
        profiles[activeProfile]?.cells[name] = LeoDelegationTarget(template: template)
    }

    mutating func renameRole(_ name: String, to newName: String, nameError: (String) -> String?) throws {
        if let message = nameError(newName) { throw Self.invalid("new_name", message) }
        if roleNames.contains(newName) { throw Self.invalid("new_name", "role \"\(newName)\" already exists") }
        guard roleNames.contains(name) else { throw Self.notFound("role \"\(name)\" not found") }
        declared[newName] = declared.removeValue(forKey: name)
        for profile in profiles.keys {
            let cell = profiles[profile]?.cells.removeValue(forKey: name)
            profiles[profile]?.cells[newName] = cell
        }
    }

    mutating func deleteRole(_ name: String) throws {
        guard roleNames.contains(name) else { throw Self.notFound("role \"\(name)\" not found") }
        if declared[name] != nil, declared.count == 1 {
            throw Self.invalid("", "cannot remove the last declared role \"\(name)\"; declare another role first")
        }
        declared[name] = nil
        for profile in profiles.keys { profiles[profile]?.cells[name] = nil }
    }

    mutating func addProfile(_ name: String, nameError: (String) -> String?) throws {
        if let message = nameError(name) { throw Self.invalid("name", message) }
        if profiles[name] != nil { throw Self.invalid("name", "profile \"\(name)\" already exists") }
        profiles[name] = Profile(description: "", cells: [:])
    }

    mutating func renameProfile(_ name: String, to newName: String, nameError: (String) -> String?) throws {
        if let message = nameError(newName) { throw Self.invalid("new_name", message) }
        if profiles[newName] != nil { throw Self.invalid("new_name", "profile \"\(newName)\" already exists") }
        guard let moved = profiles.removeValue(forKey: name) else { throw Self.notFound("profile \"\(name)\" not found") }
        profiles[newName] = moved
        if activeProfile == name { activeProfile = newName }
    }

    mutating func duplicateProfile(_ name: String, as newName: String, nameError: (String) -> String?) throws {
        if let message = nameError(newName) { throw Self.invalid("new_name", message) }
        if profiles[newName] != nil { throw Self.invalid("new_name", "profile \"\(newName)\" already exists") }
        guard let source = profiles[name] else { throw Self.notFound("profile \"\(name)\" not found") }
        profiles[newName] = source
    }

    mutating func deleteProfile(_ name: String) throws {
        if name == activeProfile { throw Self.invalid("", "cannot remove active profile \"\(name)\"") }
        guard profiles.removeValue(forKey: name) != nil else { throw Self.notFound("profile \"\(name)\" not found") }
    }
}
