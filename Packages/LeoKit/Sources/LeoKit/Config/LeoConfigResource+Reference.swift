import Foundation

extension LeoConfigResource {
    /// This resource with a plain string field drawn as a pick from another
    /// collection's names (the client's `default_host` over the hosts), which
    /// the daemon's schema can't say. A field the daemon already types, or one
    /// that isn't there, is left as it is.
    public func referencing(_ fieldKey: String, to collection: String, emptyLabel: String) -> LeoConfigResource {
        guard let current = field(fieldKey), current.type == .string else { return self }
        let replacement = LeoConfigField(
            key: current.key, label: current.label, help: current.help, warning: current.warning, group: current.group,
            advanced: current.advanced, type: .reference, defaultValue: current.defaultValue, constraints: current.constraints,
            restart: current.restart, multiline: false, format: nil, nullable: current.nullable, options: [],
            references: collection, emptyLabel: emptyLabel, hintsByHarness: current.hintsByHarness
        )
        return LeoConfigResource(
            key: key, label: label, kind: kind, section: section, actions: actions, harnessOptions: harnessOptions, restart: restart,
            fields: fields.map { $0.key == fieldKey ? replacement : $0 }, subsections: subsections
        )
    }
}
