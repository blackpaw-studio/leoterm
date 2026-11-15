import Foundation
import Testing

@testable import LeoKit

struct LeoConfigReferenceFieldTests {
    private static let client = LeoConfigResource(
        key: "client", kind: .singleton, fields: [
            LeoConfigField(key: "default_host", label: "Default host", help: "default remote host", type: .string),
            LeoConfigField(key: "other", type: .string),
        ]
    )

    @Test func aStringFieldCanBeRenderedAsAReferenceToACollection() throws {
        let resource = Self.client.referencing("default_host", to: "hosts", emptyLabel: "none")
        let field = try #require(resource.field("default_host"))

        #expect(field.type == .reference)
        #expect(field.references == "hosts")
        #expect(field.emptyLabel == "none")
        #expect(field.label == "Default host")
        #expect(field.help == "default remote host")
        #expect(resource.field("other")?.type == .string)
    }

    @Test func aFieldThatIsAlreadyTypedByTheDaemonIsLeftAlone() throws {
        let typed = LeoConfigResource(key: "client", fields: [
            LeoConfigField(key: "default_host", type: .reference, references: "machines", emptyLabel: "nobody"),
        ])
        let resource = typed.referencing("default_host", to: "hosts", emptyLabel: "none")

        #expect(resource == typed)
    }

    @Test func aMissingFieldChangesNothing() {
        #expect(Self.client.referencing("nope", to: "hosts", emptyLabel: "none") == Self.client)
    }

    @Test func aDraftChecksItsReferencesAgainstTheValidatorItWasGiven() throws {
        let resource = Self.client.referencing("default_host", to: "hosts", emptyLabel: "none")
        let document = LeoConfigDocument(revision: "r", values: [:])
        var draft = LeoConfigDraft(document: document, validator: LeoConfigValidator(resource: resource, references: ["hosts": ["alpha"]]))
        draft.set("default_host", .string("beta"))
        #expect(!draft.canSave)

        let refreshed = draft.validated(by: LeoConfigValidator(resource: resource, references: ["hosts": ["alpha", "beta"]]))

        #expect(refreshed.canSave)
        #expect(refreshed.patch == ["default_host": .string("beta")])
    }
}
