import Foundation

/// Reads files out of a plugin folder that is untrusted input: a symlink can
/// point anywhere, so every read resolves symlinks, requires the result to be
/// a regular file strictly inside the folder, and caps its size.
public enum LeoPluginBundleFile {
    public struct Refusal: Error, Equatable {
        public let message: String
    }

    /// Resolves symlinks, then requires a regular file strictly inside `folder`
    /// no larger than `maxBytes`.
    public static func regularFile(_ file: URL, within folder: URL, maxBytes: Int) throws -> URL {
        let resolved = file.resolvingSymlinksInPath()
        guard LeoPluginPathContainment.isContained(resolved: resolved, in: folder.resolvingSymlinksInPath()) else {
            throw Refusal(message: "it resolves outside the plugin folder")
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else { throw Refusal(message: "it is not a regular file") }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
        guard size <= maxBytes else { throw Refusal(message: "it is larger than \(maxBytes / 1024 / 1024) MB") }
        return resolved
    }

    public static func read(_ file: URL, within folder: URL, maxBytes: Int) throws -> Data {
        let resolved = try regularFile(file, within: folder, maxBytes: maxBytes)
        guard let data = try? Data(contentsOf: resolved) else { throw Refusal(message: "it can't be read") }
        return data
    }

    /// The manifest of the plugin in `directory`, validated.
    public static func manifest(in directory: URL) -> LeoPluginManifestValidation {
        let file = directory.appendingPathComponent(LeoPluginGitInstaller.manifestFileName)
        let data: Data
        do {
            data = try read(file, within: directory, maxBytes: LeoPluginManifestValidator.maxManifestBytes)
        } catch let refusal as Refusal {
            return .refused("leo-plugin.json: \(refusal.message)")
        } catch {
            return .refused("leo-plugin.json can't be read")
        }
        return LeoPluginManifestValidator.validate(data)
    }

    /// The plugin's JS bundle as text, with the same checks the installer ran.
    /// Read again on every launch because the folder is writable by anything
    /// running as the user.
    public static func readMain(_ main: String, in directory: URL) throws -> String {
        let data = try read(
            directory.appendingPathComponent(main), within: directory, maxBytes: LeoPluginGitInstaller.maxMainBytes)
        guard let text = String(data: data, encoding: .utf8) else { throw Refusal(message: "it is not valid UTF-8") }
        return text
    }
}
