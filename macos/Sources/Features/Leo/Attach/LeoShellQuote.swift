import Foundation

enum LeoShellQuoteError: Error, Equatable {
    case nulByte
}

func leoShellQuote(_ value: String) throws -> String {
    guard !value.contains("\0") else { throw LeoShellQuoteError.nulByte }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
