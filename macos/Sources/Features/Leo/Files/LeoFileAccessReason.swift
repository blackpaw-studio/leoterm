import Foundation

/// Why a file operation failed, in the app's words with untrusted text set
/// into them: a file name, a server's message, a system's description.
/// Nothing is cleaned until the reason is rendered, so every piece is
/// cleaned exactly once, where it is shown (`LeoFileAccessError`).
///
/// Written as a string: literal text is the app's, and each interpolated
/// `String` is untrusted -- `"kept as \(name)"`. Numbers, and text the app
/// wrote itself (`\(verbatim:)`), are the app's.
struct LeoFileAccessReason: Equatable, Sendable, ExpressibleByStringInterpolation {
    enum Part: Equatable, Sendable {
        /// Shown on one line, its own quotes kept.
        case app(String)
        /// Cleaned like a server's text and isolated in its own direction.
        case untrusted(String)
    }

    /// Adjacent app words merged and empty ones dropped, so a reason
    /// equals any other spelling of the same words.
    let parts: [Part]

    init(parts: [Part]) {
        self.parts = parts.reduce(into: []) { merged, part in
            switch (merged.last, part) {
            case (_, .app("")): break
            case let (.app(previous)?, .app(text)): merged[merged.count - 1] = .app(previous + text)
            default: merged.append(part)
            }
        }
    }

    init(stringLiteral value: String) {
        self.init(parts: [.app(value)])
    }

    init(stringInterpolation: Interpolation) {
        self.init(parts: stringInterpolation.parts)
    }

    /// A reason that is untrusted text in its entirety.
    static func untrusted(_ text: String) -> LeoFileAccessReason {
        LeoFileAccessReason(parts: [.untrusted(text)])
    }

    static func + (lhs: LeoFileAccessReason, rhs: LeoFileAccessReason) -> LeoFileAccessReason {
        LeoFileAccessReason(parts: lhs.parts + rhs.parts)
    }

    /// The reason as shown: one line, each untrusted piece cleaned and
    /// isolated.
    var rendered: String {
        parts.map { part in
            switch part {
            case let .app(text): LeoSFTPServerText.appText(text)
            case let .untrusted(text): LeoSFTPServerText.isolated(text)
            }
        }
        .joined()
        .trimmingCharacters(in: .whitespaces)
    }

    struct Interpolation: StringInterpolationProtocol {
        fileprivate private(set) var parts: [Part] = []

        init(literalCapacity: Int, interpolationCount: Int) {
            parts.reserveCapacity(interpolationCount * 2 + 1)
        }

        mutating func appendLiteral(_ literal: String) {
            parts.append(.app(literal))
        }

        mutating func appendInterpolation(_ text: String) {
            parts.append(.untrusted(text))
        }

        mutating func appendInterpolation(_ number: some BinaryInteger) {
            parts.append(.app(String(number)))
        }

        /// Text the app wrote itself (a constant, a status code's name).
        mutating func appendInterpolation(verbatim text: String) {
            parts.append(.app(text))
        }
    }
}
