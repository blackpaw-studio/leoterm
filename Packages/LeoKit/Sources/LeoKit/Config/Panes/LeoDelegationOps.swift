import Foundation

/// What `LeoDelegationOps.load` read.
public struct LeoDelegationLoad: Sendable {
    public var document: LeoDelegationDocument?
    /// The daemon's name rule, for role and profile names.
    public var namePattern: String?
    /// For the "edit on the web" link.
    public var webDocument: LeoConfigDocument?
    /// Why the document couldn't be read.
    public var failure: Error?

    public init(document: LeoDelegationDocument? = nil, namePattern: String? = nil, webDocument: LeoConfigDocument? = nil, failure: Error? = nil) {
        self.document = document
        self.namePattern = namePattern
        self.webDocument = webDocument
        self.failure = failure
    }
}

/// One delegation write, as the pane's state needs to hear of it.
public struct LeoDelegationWriteOutcome: Sendable {
    public enum Reply: Sendable {
        /// An Overwrite's fresh read failed; nothing was sent.
        case readFailed(Error)
        /// The edit the operation names is no longer open.
        case nothingToSend
        case failed(Error)
        /// `rebasing` names the open edits that may follow the write onto the
        /// new document; `readBack` is that document, nil when it couldn't be read.
        case sent(LeoDelegationWriteResult, rebasing: Set<LeoDelegationEditor>, readBack: LeoDelegationDocument?)
    }

    public let operation: LeoDelegationOperation
    /// An Overwrite's fresh read, which becomes the pane's document whatever the write does.
    public let fresh: LeoDelegationDocument?
    /// The revision the answered write went out with.
    public let sentWith: String?
    public let reply: Reply

    public init(operation: LeoDelegationOperation, fresh: LeoDelegationDocument?, sentWith: String?, reply: Reply) {
        self.operation = operation
        self.fresh = fresh
        self.sentWith = sentWith
        self.reply = reply
    }
}

/// The reads and writes behind `LeoDelegationPaneState`, over any
/// `LeoConfigClient`. Stateless: each returns a value outcome that the Mac
/// model awaits inline and the iOS reducer feeds back as an action.
public enum LeoDelegationOps {
    public typealias Send = @Sendable (String) async throws -> LeoDelegationWriteResult

    /// The document, then the schema's name rule and the web document (both
    /// optional: a failure there leaves names to the daemon and no web link).
    public static func load(client: any LeoConfigClient) async -> LeoDelegationLoad {
        do {
            let document = try await client.delegation()
            let namePattern = (try? await client.schema())?.namePattern
            let web = try? await client.document("web")
            return LeoDelegationLoad(document: document, namePattern: namePattern, webDocument: web)
        } catch {
            return LeoDelegationLoad(failure: error)
        }
    }

    /// What activating `profile` would change; nothing is written.
    public static func preview(_ profile: String, client: any LeoConfigClient) async -> LeoDelegationPreviewState {
        do {
            return .loaded(try await client.delegationPreview(profile: profile))
        } catch {
            return .failed(profile: profile, message: LeoDelegationPaneState.message(for: error))
        }
    }

    /// Sends `operation`, built from `edits` over `document`.
    ///
    /// A form edit goes against the revision its edit was based on, mapped
    /// through `revisions`; anything else against the document's.
    /// `retryingConflict` resends once against the current revision (the
    /// enabled switch: the write is the user's whole intent). `overwriting`
    /// reads the document fresh first and sends against that. The open edits
    /// whose base is the revision the write went out with are named for the
    /// state to rebase, judged before the tracker learns the write.
    public static func write(
        _ operation: LeoDelegationOperation, edits: LeoDelegationEdits, document: LeoDelegationDocument, client: any LeoConfigClient,
        revisions: LeoConfigRevisionTracker, retryingConflict: Bool = false, overwriting: Bool = false
    ) async -> LeoDelegationWriteOutcome {
        var base = document
        var ifMatch = revisions.resolve(edits.revision(for: operation, in: document))
        var fresh: LeoDelegationDocument?
        if overwriting {
            do {
                base = try await client.delegation()
            } catch {
                return LeoDelegationWriteOutcome(operation: operation, fresh: nil, sentWith: nil, reply: .readFailed(error))
            }
            fresh = base
            ifMatch = base.revision
        }
        guard let send = request(operation, edits: edits, against: base, client: client) else {
            return LeoDelegationWriteOutcome(operation: operation, fresh: fresh, sentWith: nil, reply: .nothingToSend)
        }
        var sentWith = ifMatch
        let result: LeoDelegationWriteResult
        do {
            do {
                result = try await send(sentWith)
            } catch LeoConfigError.conflict(let current) where retryingConflict {
                sentWith = current
                result = try await send(current)
            }
        } catch {
            return LeoDelegationWriteOutcome(operation: operation, fresh: fresh, sentWith: sentWith, reply: .failed(error))
        }
        let rebasing = edits.editorsBased(on: sentWith, revisions: revisions)
        revisions.recordWrite(from: sentWith, to: result.revision)
        let readBack = await readBack(result, client: client)
        return LeoDelegationWriteOutcome(
            operation: operation, fresh: fresh, sentWith: sentWith, reply: .sent(result, rebasing: rebasing, readBack: readBack)
        )
    }

    /// The document a write left: the reply carries it, else it is read.
    public static func readBack(_ result: LeoDelegationWriteResult, client: any LeoConfigClient) async -> LeoDelegationDocument? {
        if let item = result.item { return item }
        return try? await client.delegation()
    }

    /// The write the operation names, built from the edit as it is over
    /// `document`: a cell sends only its edited keys laid over the current
    /// target, the hide list its added and removed names over the current list.
    public static func request(
        _ operation: LeoDelegationOperation, edits: LeoDelegationEdits, against document: LeoDelegationDocument, client: any LeoConfigClient
    ) -> Send? {
        switch operation {
        case .cell:
            guard let editor = edits.cell else { return nil }
            let (profile, role) = (editor.profile, editor.role)
            let target = editor.edit.merged(onto: LeoDelegationMatrix(document).cell(profile: profile, role: role)?.target)
            return { try await client.setDelegationCell(profile: profile, role: role, target: target, ifMatch: $0) }
        case .useFor:
            guard let editor = edits.useFor else { return nil }
            let (role, text) = (editor.role, editor.text)
            return { try await client.setRoleUseFor(role: role, useFor: text, ifMatch: $0) }
        case .hiddenAgents:
            guard let edit = edits.hiddenAgents else { return nil }
            let names = edit.edit.applied(to: document.hideNativeAgents).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return { try await client.setHiddenAgents(names, ifMatch: $0) }
        default:
            return structureRequest(operation, client: client)
        }
    }

    private static func structureRequest(_ operation: LeoDelegationOperation, client: any LeoConfigClient) -> Send? {
        switch operation {
        case .cell, .useFor, .hiddenAgents: nil
        case .enabled(let enabled): { try await client.setDelegationEnabled(enabled, ifMatch: $0) }
        case .activate(let profile): { try await client.setActiveProfile(profile, ifMatch: $0) }
        case .addRole(let name, let template): { try await client.addDelegationRole(name: name, template: template, ifMatch: $0) }
        case .renameRole(let name, let newName): { try await client.renameDelegationRole(name, to: newName, ifMatch: $0) }
        case .deleteRole(let name): { try await client.deleteDelegationRole(name, ifMatch: $0) }
        case .addProfile(let name): { try await client.addDelegationProfile(name: name, ifMatch: $0) }
        case .renameProfile(let name, let newName): { try await client.renameDelegationProfile(name, to: newName, ifMatch: $0) }
        case .duplicateProfile(let name, let newName): { try await client.duplicateDelegationProfile(name, as: newName, ifMatch: $0) }
        case .deleteProfile(let name): { try await client.deleteDelegationProfile(name, ifMatch: $0) }
        }
    }
}
