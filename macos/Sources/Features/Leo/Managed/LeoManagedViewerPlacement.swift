import Foundation

/// B-341: writes `LeoViewerPlacementDefault`'s edit to a managed `leo.yaml`.
/// The bundled leo loads and validates the edited copy first, and the file
/// must still hold the bytes that were scanned when it's replaced. The
/// daemon reads `leo.yaml` again for every dispatch, so nothing restarts.
struct LeoManagedViewerPlacement: Sendable {
    enum Outcome: Equatable, Sendable {
        case written
        case present
        case skipped(reason: String)
        case failed(message: String)
    }

    /// The validation copy's mode: `leo.yaml` can hold secrets.
    static let candidateMode: mode_t = 0o600
    static let validationTimeout: TimeInterval = 30

    let runner: any LeoProcessRunning
    let fileSystem: any LeoFileSystem
    let bundledLeo: String
    let configURL: URL
    let makeToken: @Sendable () -> String

    func apply() async -> Outcome {
        guard fileSystem.kind(at: configURL) == .file else { return .skipped(reason: "leo.yaml isn’t a regular file") }
        let original: Data
        do {
            original = try fileSystem.read(configURL)
        } catch {
            return .failed(message: "reading leo.yaml: \(error)")
        }
        // Never rewrite what doesn't round-trip as UTF-8 text, byte for byte.
        guard let yaml = String(bytes: original, encoding: .utf8), Data(yaml.utf8) == original else {
            return .skipped(reason: "leo.yaml isn’t UTF-8 text")
        }
        switch LeoViewerPlacementDefault.migrate(yaml: yaml, pathKind: .file) {
        case .present: return .present
        case .skip(let reason): return .skipped(reason: reason)
        case .insert(let edited): return await replace(original, with: Data(edited.utf8))
        }
    }

    private func replace(_ original: Data, with edited: Data) async -> Outcome {
        let candidate = LeoDiskFileSystem.temporaryURL(for: configURL, token: makeToken())
        defer { try? fileSystem.remove(candidate) }
        do {
            try fileSystem.writeAtomically(edited, to: candidate, mode: Self.candidateMode)
        } catch {
            return .failed(message: "writing the edited copy: \(error)")
        }
        if let problem = await validate(candidate) { return .failed(message: problem) }
        // A save (the daemon's or a person's) during validation wins.
        guard fileSystem.kind(at: configURL) == .file, (try? fileSystem.read(configURL)) == original else {
            return .skipped(reason: "leo.yaml changed while the edit was being checked")
        }
        do {
            try fileSystem.writeAtomically(edited, to: configURL, mode: fileSystem.mode(at: configURL) ?? Self.candidateMode)
        } catch {
            return .failed(message: "replacing leo.yaml: \(error)")
        }
        return .written
    }

    /// Nil when leo loads and validates `url`. Its output holds the config's
    /// secrets, so only the exit status is kept.
    private func validate(_ url: URL) async -> String? {
        let arguments = ["config", "show", "--json", "--config", url.path]
        do {
            let result = try await runner.run(executable: bundledLeo, arguments: arguments, timeout: Self.validationTimeout)
            return result.status == 0 ? nil : "leo rejected the edited config (exit \(result.status))"
        } catch {
            return "leo config show didn’t run: \(error)"
        }
    }
}
