import Foundation

/// What `LeoConfigCollectionOps.load` read. A read that failed leaves its
/// field nil and names the failure; what was read before it is kept.
public struct LeoConfigCollectionLoad: Sendable {
    public var schema: LeoConfigSchema?
    public var webDocument: LeoConfigDocument?
    public var references: [String: [String]]
    public var collection: LeoConfigCollection?
    /// Why the schema or the collection couldn't be read.
    public var failure: Error?
}

/// One write, as the collection pane's state needs to hear of it.
public struct LeoConfigWriteOutcome: Sendable {
    public let result: Result<LeoConfigWriteResult, Error>
    /// The revision the write that was answered went out with: the pane's own,
    /// or the current one after a retried conflict.
    public let sentWith: String
    /// The open draft was based on `sentWith`, so reading back may rebase it.
    public let draftWasCurrent: Bool
    /// The list read after a successful write.
    public let collection: Result<LeoConfigCollection, Error>?
}

public enum LeoConfigOverwriteOutcome: Sendable {
    case readFailed(Error)
    /// The fresh copy already has every edit.
    case nothingToSend(replayed: LeoConfigDraft, collection: Result<LeoConfigCollection, Error>)
    case sent(replayed: LeoConfigDraft, outcome: LeoConfigWriteOutcome)
}

/// The reads and writes behind `LeoConfigCollectionState`, over any
/// `LeoConfigClient`. Stateless: each returns a value outcome that the Mac
/// model awaits inline and the iOS reducer feeds back as an action.
public enum LeoConfigCollectionOps {
    /// The schema, the web document (for the "edit on the web" link), the
    /// names behind the schema's reference fields (a task's template, so they
    /// pick from, and are checked against, what exists; a collection that
    /// can't be read is left unchecked, the daemon still judges), then the
    /// collection.
    public static func load(
        resource: String, client: any LeoConfigClient, references: [String: [String]]
    ) async -> LeoConfigCollectionLoad {
        var load = LeoConfigCollectionLoad(references: references)
        do {
            let schema = try await client.schema()
            load.schema = schema
            load.webDocument = try? await client.document("web")
            let wanted = Set(schema.resource(resource)?.fields.compactMap { $0.type == .reference ? $0.references : nil } ?? [])
            for key in wanted where load.references[key] == nil && key != resource {
                if let list = try? await client.collection(key) { load.references[key] = list.items.map(\.name) }
            }
            load.collection = try await client.collection(resource)
        } catch {
            load.failure = error
        }
        return load
    }

    /// Runs `operation` with `ifMatch`, then reads the list again.
    ///
    /// `retryingConflict` resends once against the current revision: for a
    /// patch that is the user's whole intent (a list toggle, a prompt file
    /// choice). That retry doesn't vouch for an open form: `draftRevision` is
    /// the revision its edits were made against, and `draftWasCurrent` is true
    /// only when it matches what the write went out with, so a form left behind
    /// by an earlier retry keeps its own revision and its Save still meets the
    /// other writer's change as a conflict. The tracker learns the write after
    /// that check, so panes holding the old revision save without a spurious
    /// conflict.
    public static func write(
        resource: String, client: any LeoConfigClient, revisions: LeoConfigRevisionTracker, ifMatch: String,
        retryingConflict: Bool = false, draftRevision: String? = nil,
        operation: @Sendable (String) async throws -> LeoConfigWriteResult
    ) async -> LeoConfigWriteOutcome {
        var sentWith = ifMatch
        let result: LeoConfigWriteResult
        do {
            do {
                result = try await operation(ifMatch)
            } catch LeoConfigError.conflict(let current) where retryingConflict {
                sentWith = current
                result = try await operation(current)
            }
        } catch {
            return LeoConfigWriteOutcome(result: .failure(error), sentWith: sentWith, draftWasCurrent: true, collection: nil)
        }
        let draftWasCurrent = draftRevision.map { revisions.resolve($0) == sentWith } ?? true
        revisions.recordWrite(from: sentWith, to: result.revision)
        let collection = await Result { try await client.collection(resource) }
        return LeoConfigWriteOutcome(result: .success(result), sentWith: sentWith, draftWasCurrent: draftWasCurrent, collection: collection)
    }

    /// Overwrite after a conflict: the item is read again, the user's edits
    /// (per key, per env entry, and a list as the names it added and removed)
    /// are replayed over that copy, and the result is sent against its
    /// revision. Another writer's list entries and keys survive; nothing is
    /// sent when their copy already has every edit.
    public static func overwrite(
        stale: LeoConfigDraft, resource: String, name: String, client: any LeoConfigClient, revisions: LeoConfigRevisionTracker
    ) async -> LeoConfigOverwriteOutcome {
        let current: LeoConfigDocument
        do {
            current = try await client.item(resource, name: name)
        } catch {
            return .readFailed(error)
        }
        let replayed = stale.rebased(onto: current)
        guard replayed.isDirty else {
            return .nothingToSend(replayed: replayed, collection: await Result { try await client.collection(resource) })
        }
        let outcome = await write(
            resource: resource, client: client, revisions: revisions, ifMatch: current.revision, draftRevision: replayed.revision,
            operation: { ifMatch in try await client.update(resource, name: name, patch: replayed.patch, ifMatch: ifMatch) }
        )
        return .sent(replayed: replayed, outcome: outcome)
    }
}

extension Result where Failure == Error {
    /// The outcome of an async throwing body.
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
