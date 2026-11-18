import Foundation

/// What `LeoConfigSingletonOps.load` read. A read that failed leaves its
/// field nil and names the failure; what was read before it is kept.
public struct LeoConfigSingletonLoad: Sendable {
    /// The schema, with the resource as the pane draws it (see `transform`).
    public var schema: LeoConfigSchema?
    public var webDocument: LeoConfigDocument?
    public var references: [String: [String]]
    public var document: LeoConfigDocument?
    /// Why the schema or the document couldn't be read.
    public var failure: Error?
}

/// One write of a singleton form, as its state needs to hear of it.
public struct LeoConfigSingletonWriteOutcome: Sendable {
    public let result: Result<LeoConfigWriteResult, Error>
    /// The revision the write went out with.
    public let sentWith: String
    /// The form's draft was based on `sentWith`, so reading back may rebase it.
    public let draftWasCurrent: Bool
    /// The document read after a successful write.
    public let document: Result<LeoConfigDocument, Error>?

    public init(
        result: Result<LeoConfigWriteResult, Error>, sentWith: String, draftWasCurrent: Bool, document: Result<LeoConfigDocument, Error>?
    ) {
        self.result = result
        self.sentWith = sentWith
        self.draftWasCurrent = draftWasCurrent
        self.document = document
    }
}

public enum LeoConfigSingletonOverwriteOutcome: Sendable {
    case readFailed(Error)
    /// The fresh copy already has every edit.
    case nothingToSend(replayed: LeoConfigDraft)
    case sent(replayed: LeoConfigDraft, outcome: LeoConfigSingletonWriteOutcome)
}

/// The reads and writes behind `LeoConfigSingletonState` (defaults, web,
/// client), over any `LeoConfigClient`. Stateless: each returns a value
/// outcome that the Mac model awaits inline and the iOS reducer feeds back
/// as an action.
public enum LeoConfigSingletonOps {
    /// The schema (with `transform` applied to the resource: a string field
    /// the app draws as a pick from a collection), the web document (for the
    /// "edit on the web" link), the names behind the resource's reference
    /// fields that `references` doesn't already hold, then the document.
    public static func load(
        resource: String, client: any LeoConfigClient, references: [String: [String]],
        transform: (@Sendable (LeoConfigResource) -> LeoConfigResource)? = nil
    ) async -> LeoConfigSingletonLoad {
        var load = LeoConfigSingletonLoad(references: references)
        do {
            var schema = try await client.schema()
            if let transform { schema = schema.transforming(resource, transform) }
            load.schema = schema
            load.webDocument = try? await client.document("web")
            let wanted = Set(schema.resource(resource)?.fields.compactMap { $0.type == .reference ? $0.references : nil } ?? [])
            for key in wanted.sorted() where load.references[key] == nil {
                if let list = try? await client.collection(key) { load.references[key] = list.items.map(\.name) }
            }
            load.document = try await client.document(resource)
        } catch {
            load.failure = error
        }
        return load
    }

    /// Sends `sent`'s patch (only the keys the user changed) against the
    /// revision it was read at, mapped through `revisions` so another pane's
    /// write isn't a conflict, then reads the document again. The tracker
    /// learns the write once it lands.
    public static func write(
        resource: String, client: any LeoConfigClient, revisions: LeoConfigRevisionTracker, sent: LeoConfigDraft
    ) async -> LeoConfigSingletonWriteOutcome {
        let ifMatch = revisions.resolve(sent.revision)
        return await send(resource: resource, client: client, revisions: revisions, ifMatch: ifMatch, draft: sent)
    }

    /// Overwrite after a conflict: the document is read again, the user's
    /// edits are replayed over that copy (another writer's list entries and
    /// keys survive), and the result is sent against its revision. Nothing is
    /// sent when their copy already has every edit.
    public static func overwrite(
        stale: LeoConfigDraft, resource: String, client: any LeoConfigClient, revisions: LeoConfigRevisionTracker
    ) async -> LeoConfigSingletonOverwriteOutcome {
        let current: LeoConfigDocument
        do {
            current = try await client.document(resource)
        } catch {
            return .readFailed(error)
        }
        let replayed = stale.rebased(onto: current)
        guard replayed.isDirty else { return .nothingToSend(replayed: replayed) }
        let outcome = await send(resource: resource, client: client, revisions: revisions, ifMatch: current.revision, draft: replayed)
        return .sent(replayed: replayed, outcome: outcome)
    }

    private static func send(
        resource: String, client: any LeoConfigClient, revisions: LeoConfigRevisionTracker, ifMatch: String, draft: LeoConfigDraft
    ) async -> LeoConfigSingletonWriteOutcome {
        let result: LeoConfigWriteResult
        do {
            result = try await client.update(resource, name: nil, patch: draft.patch, ifMatch: ifMatch)
        } catch {
            return LeoConfigSingletonWriteOutcome(result: .failure(error), sentWith: ifMatch, draftWasCurrent: true, document: nil)
        }
        let draftWasCurrent = revisions.resolve(draft.revision) == ifMatch
        revisions.recordWrite(from: ifMatch, to: result.revision)
        let document = await Result { try await client.document(resource) }
        return LeoConfigSingletonWriteOutcome(result: .success(result), sentWith: ifMatch, draftWasCurrent: draftWasCurrent, document: document)
    }
}

extension LeoConfigSchema {
    /// This schema with `key`'s resource passed through `transform`.
    public func transforming(_ key: String, _ transform: (LeoConfigResource) -> LeoConfigResource) -> LeoConfigSchema {
        LeoConfigSchema(
            schemaVersion: schemaVersion, namePattern: namePattern,
            resources: resources.map { $0.key == key ? transform($0) : $0 }, harnesses: harnesses
        )
    }
}
