import Foundation

/// A call a `LeoFakeConfigClient` received, for assertions in model tests.
public enum LeoFakeConfigCall: Equatable, Sendable {
    case versionInfo
    case schema
    case document(String)
    case collection(String)
    case item(resource: String, name: String)
    case update(resource: String, name: String?, patch: [String: LeoConfigValue], ifMatch: String)
    case add(resource: String, name: String, values: [String: LeoConfigValue], ifMatch: String)
    case rename(resource: String, name: String, newName: String, ifMatch: String)
    case duplicate(resource: String, name: String, newName: String, ifMatch: String)
    case delete(resource: String, name: String, ifMatch: String)
    case runTask(String)
    case taskHistory(name: String, limit: Int)
    case taskLog(name: String, file: String)
    case taskPrompt(String)
    case saveTaskPrompt(name: String, content: String, ifMatch: String)
    case cronPreview(String)
}

/// What a fake daemon knows about its tasks beyond their config: run history
/// (newest first, per task), run logs by file, and the workspace's prompt
/// files by path. A protected prompt file is one the daemon refuses to serve.
public struct LeoFakeTaskData: Sendable {
    public var runs: [String: [LeoTaskRun]]
    public var logs: [String: String]
    public var truncatedLogs: Set<String>
    public var prompts: [String: String]
    public var protectedPrompts: Set<String>

    public init(
        runs: [String: [LeoTaskRun]] = [:], logs: [String: String] = [:], truncatedLogs: Set<String> = [],
        prompts: [String: String] = [:], protectedPrompts: Set<String> = []
    ) {
        self.runs = runs
        self.logs = logs
        self.truncatedLogs = truncatedLogs
        self.prompts = prompts
        self.protectedPrompts = protectedPrompts
    }
}

/// An in-memory `LeoConfigClient` with the daemon's revision semantics, for
/// model tests and fixture launches built before (or without) a daemon.
///
/// leo.yaml has one revision: every successful write bumps it, a write with a
/// stale `If-Match` is a 409 that changes nothing, and a missing one is a
/// 428. It enforces the schema's actions and the name rules, renames
/// rewrite references, and a delete refuses an item still referenced; the
/// last is this fake's assumption about the daemon's 422 text. A secret is
/// stored as set / not set only, and a key written as null is dropped. Anything else
/// the daemon would reject (a 422 on a value, a timeout) is scripted with
/// `failNextWrite` / `failNextRead`.
public actor LeoFakeConfigClient: LeoConfigClient {
    private let schemaValue: LeoConfigSchema
    private let version: LeoDaemonVersionInfo
    private var singletons: [String: LeoConfigItem]
    private var collections: [String: [String: LeoConfigItem]]
    private var revisionNumber = 0
    private var restartRequired = LeoConfigRestartRequired()
    private var nextWriteFailure: (any Error)?
    private var nextReadFailure: (any Error)?
    private var isHoldingReads = false
    private var heldReads: [CheckedContinuation<Void, Never>] = []
    private var taskData: LeoFakeTaskData

    public private(set) var calls: [LeoFakeConfigCall] = []

    public init(
        schema: LeoConfigSchema, singletons: [String: LeoConfigItem] = [:], collections: [String: [LeoConfigItem]] = [:],
        tasks: LeoFakeTaskData = LeoFakeTaskData(),
        version: LeoDaemonVersionInfo = LeoDaemonVersionInfo(version: "0.0.0-fake", capabilities: [LeoConfigAPI.capability])
    ) {
        schemaValue = schema
        taskData = tasks
        self.version = version
        self.singletons = singletons
        self.collections = collections.mapValues { items in
            Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    // MARK: reads

    public func versionInfo() async throws -> LeoDaemonVersionInfo {
        calls.append(.versionInfo)
        try await beforeRead()
        return version
    }

    public func schema() async throws -> LeoConfigSchema {
        calls.append(.schema)
        try await beforeRead()
        guard version.supports(LeoConfigAPI.capability) else { throw LeoConfigError.unsupported }
        return schemaValue
    }

    public func document(_ resource: String) async throws -> LeoConfigDocument {
        calls.append(.document(resource))
        try await beforeRead()
        guard let single = singletons[resource] else { throw try notFoundResource(resource) }
        return document(of: single, named: nil)
    }

    public func collection(_ resource: String) async throws -> LeoConfigCollection {
        calls.append(.collection(resource))
        try await beforeRead()
        guard let items = collections[resource] else { throw try notFoundResource(resource) }
        return LeoConfigCollection(revision: revision, items: items.values.sorted { $0.name < $1.name })
    }

    public func item(_ resource: String, name: String) async throws -> LeoConfigDocument {
        calls.append(.item(resource: resource, name: name))
        try await beforeRead()
        return document(of: try existing(resource, name), named: name)
    }

    // MARK: writes

    public func update(_ resource: String, name: String?, patch: [String: LeoConfigValue], ifMatch: String) async throws -> LeoConfigWriteResult {
        calls.append(.update(resource: resource, name: name, patch: patch, ifMatch: ifMatch))
        try beforeWrite(ifMatch)
        if let name {
            var item = try existing(resource, name)
            item = LeoConfigItem(name: name, values: Self.merged(item.values, patch), inherited: item.inherited, effectiveHarness: item.effectiveHarness)
            collections[resource]?[name] = item
        } else {
            guard let single = singletons[resource] else { throw try notFoundResource(resource) }
            singletons[resource] = LeoConfigItem(
                name: "", values: Self.merged(single.values, patch), inherited: single.inherited, effectiveHarness: single.effectiveHarness
            )
        }
        return committed(resource)
    }

    public func add(_ resource: String, name: String, values: [String: LeoConfigValue], ifMatch: String) async throws -> LeoConfigWriteResult {
        calls.append(.add(resource: resource, name: name, values: values, ifMatch: ifMatch))
        try beforeWrite(ifMatch)
        let definition = try collectionDefinition(resource, supporting: .add)
        try checkName(name, field: "name", in: definition, excluding: nil)
        collections[resource, default: [:]][name] = LeoConfigItem(name: name, values: Self.merged(try addDefaults(resource, name, values), values))
        return committed(resource, item: name)
    }

    public func rename(_ resource: String, name: String, to newName: String, ifMatch: String) async throws -> LeoConfigWriteResult {
        calls.append(.rename(resource: resource, name: name, newName: newName, ifMatch: ifMatch))
        try beforeWrite(ifMatch)
        let definition = try collectionDefinition(resource, supporting: .rename)
        let moved = try existing(resource, name)
        try checkName(newName, field: "new_name", in: definition, excluding: name)
        collections[resource]?[name] = nil
        collections[resource]?[newName] = LeoConfigItem(name: newName, values: moved.values, inherited: moved.inherited, effectiveHarness: moved.effectiveHarness)
        rewriteReferences(to: resource, from: name, to: newName)
        return committed(resource)
    }

    public func duplicate(_ resource: String, name: String, as newName: String, ifMatch: String) async throws -> LeoConfigWriteResult {
        calls.append(.duplicate(resource: resource, name: name, newName: newName, ifMatch: ifMatch))
        try beforeWrite(ifMatch)
        let definition = try collectionDefinition(resource, supporting: .duplicate)
        let source = try existing(resource, name)
        try checkName(newName, field: "new_name", in: definition, excluding: nil)
        collections[resource]?[newName] = LeoConfigItem(name: newName, values: source.values, inherited: source.inherited, effectiveHarness: source.effectiveHarness)
        return committed(resource, item: newName)
    }

    public func delete(_ resource: String, name: String, ifMatch: String) async throws -> LeoConfigWriteResult {
        calls.append(.delete(resource: resource, name: name, ifMatch: ifMatch))
        try beforeWrite(ifMatch)
        _ = try collectionDefinition(resource, supporting: .delete)
        _ = try existing(resource, name)
        if let user = referrer(of: resource, name: name) {
            throw LeoConfigError.invalid([LeoConfigFieldError(field: "", message: "\(name) is still used by \(user)")])
        }
        collections[resource]?[name] = nil
        return committed(resource)
    }

    /// What the daemon fills in when it adds a task: a schedule is required,
    /// the prompt file defaults to `prompts/<name>.md`, and it starts disabled.
    private func addDefaults(_ resource: String, _ name: String, _ values: [String: LeoConfigValue]) throws -> [String: LeoConfigValue] {
        guard resource == "tasks" else { return [:] }
        guard let schedule = values["schedule"]?.stringValue, !schedule.isEmpty else {
            throw LeoConfigError.invalid([LeoConfigFieldError(field: "schedule", message: "schedule is required")])
        }
        return ["prompt_file": .string("prompts/\(name).md"), "enabled": .bool(false)]
    }

    // MARK: scripting

    /// The next write throws `error` before touching anything.
    public func failNextWrite(with error: any Error) {
        nextWriteFailure = error
    }

    /// The next read throws `error`.
    public func failNextRead(with error: any Error) {
        nextReadFailure = error
    }

    /// Reads suspend until `releaseReads()`: a way to make a reply late.
    public func holdReads() {
        isHoldingReads = true
    }

    public var heldReadCount: Int { heldReads.count }

    public func releaseReads() {
        isHoldingReads = false
        let waiting = heldReads
        heldReads = []
        for continuation in waiting { continuation.resume() }
    }

    /// An edit made outside the app (the CLI, the web UI): it changes the
    /// values and bumps the revision without the app having sent it.
    public func externalChange(_ resource: String, name: String? = nil, values: [String: LeoConfigValue]) {
        if let name, let item = collections[resource]?[name] {
            collections[resource]?[name] = LeoConfigItem(name: name, values: item.values.merging(values) { _, new in new }, inherited: item.inherited, effectiveHarness: item.effectiveHarness)
        } else if let single = singletons[resource] {
            singletons[resource] = LeoConfigItem(name: "", values: single.values.merging(values) { _, new in new }, inherited: single.inherited, effectiveHarness: single.effectiveHarness)
        }
        revisionNumber += 1
    }

    /// An edit to a prompt file made outside the app: its revision changes.
    public func externalPromptChange(file: String, content: String) {
        taskData.prompts[file] = content
    }

    /// What the daemon does when it restarts: the pending flags reset.
    public func clearRestartRequired() {
        restartRequired = LeoConfigRestartRequired()
    }

    public var currentRevision: String { revision }

    // MARK: internals

    /// What the daemon stores after a write. An object sent over an object
    /// (a nested group, an env map) merges entry by entry; anything else
    /// replaces. A secret's replace or clear becomes set / not set (the value
    /// is never kept or returned), and a key sent as null is dropped.
    private static func merged(_ stored: [String: LeoConfigValue], _ patch: [String: LeoConfigValue]) -> [String: LeoConfigValue] {
        var result = stored
        for (key, value) in patch {
            if case .object(let entries) = value, let current = stored[key]?.objectValue {
                result[key] = normalised(.object(current.merging(entries) { $1 }))
            } else {
                result[key] = normalised(value)
            }
        }
        return result.filter { !$0.value.isNull }
    }

    /// What the daemon stores for a written value: a secret as set / not set,
    /// and inside an object a `null` or cleared entry is gone. An object of
    /// plain strings is an env map.
    private static func normalised(_ value: LeoConfigValue) -> LeoConfigValue {
        switch value {
        case .secretReplace: .secret(isSet: true)
        case .secretClear: .secret(isSet: false)
        case .object(let entries):
            stored(entries.filter { entry in
                if case .secretClear = entry.value { false } else { !entry.value.isNull }
            }.mapValues(normalised))
        default: value
        }
    }

    private static func stored(_ entries: [String: LeoConfigValue]) -> LeoConfigValue {
        let strings = entries.compactMapValues(\.stringValue)
        return strings.count == entries.count ? .map(strings) : .object(entries)
    }

    private var revision: String { "sha256:fake-\(revisionNumber)" }

    private func document(of item: LeoConfigItem, named name: String?) -> LeoConfigDocument {
        LeoConfigDocument(revision: revision, name: name, values: item.values, inherited: item.inherited, effectiveHarness: item.effectiveHarness)
    }

    private func beforeRead() async throws {
        if let failure = nextReadFailure {
            nextReadFailure = nil
            throw failure
        }
        if isHoldingReads {
            await withCheckedContinuation { heldReads.append($0) }
        }
    }

    fileprivate func takeWriteFailure() -> (any Error)? {
        defer { nextWriteFailure = nil }
        return nextWriteFailure
    }

    private func beforeWrite(_ ifMatch: String) throws {
        if let failure = takeWriteFailure() { throw failure }
        guard !ifMatch.isEmpty else { throw LeoConfigError.revisionRequired }
        guard ifMatch == revision else { throw LeoConfigError.conflict(currentRevision: revision) }
    }

    /// Bumps the revision, raises the restart flags the resource's scope
    /// names, and answers the write.
    private func committed(_ resource: String, item name: String? = nil) -> LeoConfigWriteResult {
        revisionNumber += 1
        switch schemaValue.resource(resource)?.restart {
        case .agents: restartRequired = LeoConfigRestartRequired(service: restartRequired.service, agents: true)
        case .service: restartRequired = LeoConfigRestartRequired(service: true, agents: restartRequired.agents)
        default: break
        }
        let written = name.flatMap { collections[resource]?[$0] }.map { document(of: $0, named: $0.name) }
        return LeoConfigWriteResult(revision: revision, restartRequired: restartRequired, item: written)
    }

    private func existing(_ resource: String, _ name: String) throws -> LeoConfigItem {
        guard let items = collections[resource] else { throw try notFoundResource(resource) }
        guard let item = items[name] else {
            throw LeoDaemonError.daemon(code: "not_found", message: "No \(resource) item \(name)", matches: [])
        }
        return item
    }

    private func notFoundResource(_ resource: String) throws -> LeoDaemonError {
        LeoDaemonError.daemon(code: "not_found", message: "No such config resource \(resource)", matches: [])
    }

    private func collectionDefinition(_ resource: String, supporting action: LeoConfigAction) throws -> LeoConfigResource {
        guard let definition = schemaValue.resource(resource), definition.kind == .collection else { throw try notFoundResource(resource) }
        guard definition.supports(action) else {
            throw LeoDaemonError.daemon(code: "not_found", message: "\(resource) does not support \(action.rawValue)", matches: [])
        }
        return definition
    }

    private func checkName(_ name: String, field: String, in definition: LeoConfigResource, excluding: String?) throws {
        let validator = LeoConfigValidator(resource: definition, namePattern: schemaValue.namePattern)
        let taken = collections[definition.key].map { Array($0.keys) } ?? []
        if let message = validator.nameError(name, existing: taken, excluding: excluding) {
            throw LeoConfigError.invalid([LeoConfigFieldError(field: field, message: message)])
        }
    }

    /// The fields of other resources that name an item of `resource`.
    private func referencingFields(to resource: String) -> [(owner: String, field: String)] {
        schemaValue.resources.flatMap { definition in
            definition.fields.filter { $0.type == .reference && $0.references == resource }.map { (definition.key, $0.key) }
        }
    }

    private func rewriteReferences(to resource: String, from old: String, to new: String) {
        for (owner, field) in referencingFields(to: resource) {
            for (name, item) in collections[owner] ?? [:] where item.values[field] == .string(old) {
                collections[owner]?[name] = LeoConfigItem(
                    name: name, values: item.values.merging([field: .string(new)]) { _, new in new },
                    inherited: item.inherited, effectiveHarness: item.effectiveHarness
                )
            }
            if let single = singletons[owner], single.values[field] == .string(old) {
                singletons[owner] = LeoConfigItem(
                    name: "", values: single.values.merging([field: .string(new)]) { _, new in new },
                    inherited: single.inherited, effectiveHarness: single.effectiveHarness
                )
            }
        }
    }

    private func referrer(of resource: String, name: String) -> String? {
        for (owner, field) in referencingFields(to: resource) {
            if let item = collections[owner]?.values.sorted(by: { $0.name < $1.name }).first(where: { $0.values[field] == .string(name) }) {
                return "\(owner)/\(item.name)"
            }
            if singletons[owner]?.values[field] == .string(name) { return owner }
        }
        return nil
    }
}

// MARK: tasks

extension LeoFakeConfigClient {
    public func runTask(_ name: String) async throws -> LeoTaskRunStart {
        calls.append(.runTask(name))
        if let failure = takeWriteFailure() { throw failure }
        _ = try existing("tasks", name)
        return LeoTaskRunStart(name: name, status: "started")
    }

    public func taskHistory(_ name: String, limit: Int) async throws -> [LeoTaskRun] {
        calls.append(.taskHistory(name: name, limit: limit))
        try await beforeRead()
        _ = try existing("tasks", name)
        return Array((taskData.runs[name] ?? []).prefix(limit))
    }

    public func taskLog(_ name: String, file: String) async throws -> LeoTaskLog {
        calls.append(.taskLog(name: name, file: file))
        try await beforeRead()
        _ = try existing("tasks", name)
        guard file.hasPrefix("\(name)-") else {
            throw LeoDaemonError.daemon(code: "bad_request", message: "log file does not match task", matches: [])
        }
        guard let text = taskData.logs[file] else {
            throw LeoDaemonError.daemon(code: "not_found", message: "log file \"\(file)\" not found", matches: [])
        }
        return LeoTaskLog(file: file, text: text, truncated: taskData.truncatedLogs.contains(file))
    }

    public func taskPrompt(_ name: String) async throws -> LeoTaskPrompt {
        calls.append(.taskPrompt(name))
        try await beforeRead()
        let file = try promptFile(of: name)
        let content = taskData.prompts[file] ?? ""
        return LeoTaskPrompt(revision: LeoTaskPrompt.revision(of: content), file: file, files: servedPromptFiles, content: content)
    }

    public func saveTaskPrompt(_ name: String, content: String, ifMatch: String) async throws -> LeoTaskPromptWrite {
        calls.append(.saveTaskPrompt(name: name, content: content, ifMatch: ifMatch))
        if let failure = takeWriteFailure() { throw failure }
        guard !ifMatch.isEmpty else { throw LeoConfigError.revisionRequired }
        let file = try promptFile(of: name)
        let current = LeoTaskPrompt.revision(of: taskData.prompts[file] ?? "")
        guard ifMatch == current else { throw LeoConfigError.conflict(currentRevision: current) }
        taskData.prompts[file] = content
        return LeoTaskPromptWrite(revision: LeoTaskPrompt.revision(of: content), file: file)
    }

    public func cronPreview(_ expression: String) async throws -> LeoCronPreview {
        calls.append(.cronPreview(expression))
        try await beforeRead()
        let fields = expression.split(separator: " ").count
        return fields == 5
            ? LeoCronPreview(valid: true, description: "Schedule \(expression)", error: nil)
            : LeoCronPreview(valid: false, description: "", error: "expected 5 fields, got \(fields)")
    }

    /// The task's configured prompt file, refused when the daemon protects it.
    private func promptFile(of name: String) throws -> String {
        let file = try existing("tasks", name).values["prompt_file"]?.stringValue ?? ""
        guard !taskData.protectedPrompts.contains(file) else {
            throw LeoConfigError.invalid([LeoConfigFieldError(field: "prompt_file", message: "\(file) is not available as a prompt")])
        }
        return file
    }

    private var servedPromptFiles: [String] {
        taskData.prompts.keys.filter { !taskData.protectedPrompts.contains($0) }.sorted()
    }
}
