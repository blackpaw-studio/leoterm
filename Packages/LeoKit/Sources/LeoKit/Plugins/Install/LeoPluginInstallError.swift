import Foundation

public enum LeoPluginInstallError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL(String)
    case invalidRef(String)
    /// `/usr/bin/git` is missing or is the Command Line Tools stub.
    case gitUnavailable
    case gitFailed(command: String, detail: String)
    case refNotFound(String)
    case shaMismatch(expected: String, actual: String)
    case manifestMissing
    case manifestRefused(String)
    case mainUnusable(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let reason): "Can't install from this URL: \(reason)."
        case .invalidRef(let ref): "'\(ref)' is not a usable branch, tag or commit name."
        case .gitUnavailable:
            "git isn't available. Install the Xcode Command Line Tools (run `xcode-select --install`) and try again."
        case .gitFailed(let command, let detail): "git \(command) failed: \(detail)"
        case .refNotFound(let ref): "The repository has no branch or tag named '\(ref)'."
        case .shaMismatch(let expected, let actual): "Fetched commit \(actual) but expected \(expected)."
        case .manifestMissing: "The repository has no leo-plugin.json at its top level."
        case .manifestRefused(let reason): "The plugin manifest was refused: \(reason)."
        case .mainUnusable(let reason): "The plugin's main file was refused: \(reason)."
        case .installFailed(let reason): "Install failed: \(reason)."
        }
    }
}
