import Foundation

/// The task routes of the config API: run, history, log, the prompt file, and
/// the cron preview. Served beside the config routes on the same transport.
public protocol LeoTaskAPI: Sendable {
    /// `POST /tasks/{name}/run`.
    func runTask(_ name: String) async throws -> LeoTaskRunStart
    /// `GET /tasks/{name}/history`, newest first (the daemon caps `limit` at 200).
    func taskHistory(_ name: String, limit: Int) async throws -> [LeoTaskRun]
    /// `GET /tasks/{name}/log`: `file` must be one of the task's own logs.
    func taskLog(_ name: String, file: String) async throws -> LeoTaskLog
    /// `GET /config/tasks/{name}/prompt`: the task's configured `prompt_file`.
    /// A protected file is a 422 on `prompt_file`.
    func taskPrompt(_ name: String) async throws -> LeoTaskPrompt
    /// `PUT /config/tasks/{name}/prompt`: writes the configured file, creating
    /// it if missing. `ifMatch` is the prompt's own revision, not leo.yaml's.
    func saveTaskPrompt(_ name: String, content: String, ifMatch: String) async throws -> LeoTaskPromptWrite
    /// `GET /cron/preview`.
    func cronPreview(_ expression: String) async throws -> LeoCronPreview
}
