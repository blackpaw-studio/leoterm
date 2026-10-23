import Foundation

@testable import LeoKit

/// Delegation documents the daemon's golden bodies are too small to exercise:
/// built by hand from the shapes in `LeoDelegationModelsTests`.
enum LeoDelegationFixtures {
    static let templates = [
        LeoDelegationTemplate(name: "coder", model: "opus"), LeoDelegationTemplate(name: "reviewer", model: "haiku"),
        LeoDelegationTemplate(name: "scout", model: "sonnet"),
    ]

    /// Two profiles (`fast` active), two declared roles, `qa` routed only by `deep`.
    static func document(
        roles: [LeoDelegationRole]? = nil, warnings: [String] = [], consults: [LeoDelegationConsult] = [], hideIsDefault: Bool = true,
        enabled: Bool = true
    ) -> LeoDelegationDocument {
        LeoDelegationDocument(
            revision: "seed", enabled: enabled, activeProfile: "fast", hideNativeAgentsIsDefault: hideIsDefault, templates: templates,
            roles: roles ?? [LeoDelegationRole(name: "coder", useFor: "writing code"), LeoDelegationRole(name: "qa", useFor: "tests")],
            profiles: [
                LeoDelegationProfile(name: "deep", roles: [
                    "coder": LeoDelegationCell(template: "coder", inheritedModel: "opus"),
                    "qa": LeoDelegationCell(template: "reviewer", model: "sonnet", effort: "high", inheritedModel: "haiku"),
                ]),
                LeoDelegationProfile(name: "fast", active: true, roles: [
                    "coder": LeoDelegationCell(template: "reviewer", inheritedModel: "haiku"),
                ]),
            ],
            warnings: warnings, recentConsults: consults
        )
    }

    /// Eight roles by six profiles: wider than the window, with an override, an
    /// effort, a long model name and unmapped cells.
    static func wide() -> LeoDelegationDocument {
        let roleNames = ["architect", "coder", "explorer", "planner", "researcher", "reviewer", "security-reviewer", "writer"]
        let profileNames = ["balanced", "cheap", "deep", "fast", "offline", "thorough"]
        let efforts = ["", "low", "medium", "high", "xhigh", "max"]
        let roles = roleNames.map { LeoDelegationRole(name: $0, useFor: "what \($0) is for") }
        let profiles = profileNames.enumerated().map { column, name in
            LeoDelegationProfile(
                name: name, description: "\(name) routing", active: name == "fast",
                roles: Dictionary(uniqueKeysWithValues: roleNames.enumerated().compactMap { row, role -> (String, LeoDelegationCell)? in
                    guard (row + column) % 5 != 0 else { return nil }
                    let template = templates[(row + column) % templates.count]
                    return (role, LeoDelegationCell(
                        template: template.name, model: (row + column) % 4 == 0 ? "claude-sonnet-5-5-20261001" : "",
                        effort: efforts[(row * 2 + column) % efforts.count], inheritedModel: template.model
                    ))
                })
            )
        }
        return LeoDelegationDocument(
            revision: "seed", activeProfile: "fast", hideNativeAgents: ["Explore", "Plan"], templates: templates, roles: roles, profiles: profiles,
            warnings: ["profile \"offline\" routes role \"writer\" to template \"drafter\", which is not installed"]
        )
    }
}
