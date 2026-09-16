import Foundation

enum LeoAPIFlavor: Equatable, Sendable {
    case legacy
    case hub

    static func select(version: String) -> Self {
        let normalized = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              components.dropFirst(2).allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return .legacy }
        return major > 0 || minor >= 29 ? .hub : .legacy
    }
}
