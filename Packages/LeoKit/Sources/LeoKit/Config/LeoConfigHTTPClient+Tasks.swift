import Foundation

extension LeoConfigHTTPClient {
    public func runTask(_ name: String) async throws -> LeoTaskRunStart {
        try await exchange("POST", "\(prefix)/tasks/\(try Self.segment(name, what: "Task name"))/run")
    }

    public func taskHistory(_ name: String, limit: Int) async throws -> [LeoTaskRun] {
        try await read("\(prefix)/tasks/\(try Self.segment(name, what: "Task name"))/history?limit=\(max(1, limit))")
    }

    public func taskLog(_ name: String, file: String) async throws -> LeoTaskLog {
        try await read("\(prefix)/tasks/\(try Self.segment(name, what: "Task name"))/log?file=\(try Self.segment(file, what: "Log file"))")
    }

    public func taskPrompt(_ name: String) async throws -> LeoTaskPrompt {
        try await read(try promptRoute(name))
    }

    public func saveTaskPrompt(_ name: String, content: String, ifMatch: String) async throws -> LeoTaskPromptWrite {
        try await exchange("PUT", try promptRoute(name), body: ["content": .string(content)], ifMatch: ifMatch)
    }

    public func cronPreview(_ expression: String) async throws -> LeoCronPreview {
        try await read("\(prefix)/cron/preview?expr=\(try Self.segment(expression, what: "Cron expression"))")
    }

    private func promptRoute(_ name: String) throws -> String {
        "\(prefix)/config/tasks/\(try Self.segment(name, what: "Task name"))/prompt"
    }
}
