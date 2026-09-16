import Foundation

enum LeoLogsCommand {
    static func build(executablePath: String, agentName: String) throws -> String {
        "\(try leoShellQuote(executablePath)) agent logs -f -- \(try leoShellQuote(agentName))"
    }
}
