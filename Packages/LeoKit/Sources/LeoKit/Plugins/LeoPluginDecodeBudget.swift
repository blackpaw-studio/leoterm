import Foundation

/// Depth and element budget shared by every `Decodable` in one plugin frame
/// (nested `pushView` trees, callback-result actions, list items, picker
/// options and form fields all draw from the same pool). Decoding is
/// synchronous, so the active budget lives in the decoding thread's
/// dictionary; the outermost `enter` creates it and its `exit` removes it.
final class LeoPluginDecodeBudget {
    private static let storageKey = "leo.plugin.decodeBudget"

    struct Scope {
        fileprivate let budget: LeoPluginDecodeBudget
        fileprivate let ownsBudget: Bool
        fileprivate let depth: Int

        func exit() {
            budget.depth -= depth
            if ownsBudget { Thread.current.threadDictionary.removeObject(forKey: LeoPluginDecodeBudget.storageKey) }
        }
    }

    private var depth = 0
    private var elements = 0

    /// Opens a level that costs `elements` and `depth`. Pair with `defer { scope.exit() }`.
    static func enter(_ decoder: any Decoder, elements: Int = 0, depth: Int = 0) throws -> Scope {
        let dictionary = Thread.current.threadDictionary
        let existing = dictionary[storageKey] as? LeoPluginDecodeBudget
        let budget = existing ?? LeoPluginDecodeBudget()
        if existing == nil { dictionary[storageKey] = budget }
        let scope = Scope(budget: budget, ownsBudget: existing == nil, depth: depth)
        budget.depth += depth
        budget.elements += elements
        if budget.depth > LeoPluginNodeLimits.maxDepth {
            scope.exit()
            throw corrupted(decoder, "tree depth exceeds limit \(LeoPluginNodeLimits.maxDepth)")
        }
        if budget.elements > LeoPluginNodeLimits.maxNodes {
            scope.exit()
            throw corrupted(decoder, "tree has more than \(LeoPluginNodeLimits.maxNodes) nodes")
        }
        return scope
    }

    private static func corrupted(_ decoder: any Decoder, _ message: String) -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: message))
    }
}
