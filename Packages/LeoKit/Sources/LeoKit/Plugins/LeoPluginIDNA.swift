import Foundation

/// Strict, dependency-free host-label conversion to ASCII (IDNA-style, RFC 3492
/// punycode). Deliberately narrower than UTS #46: a label that needs any
/// guesswork is refused rather than mapped.
enum LeoPluginIDNA {
    private static let acePrefix = "xn--"
    private static let maxLabelLength = 63

    /// ASCII (LDH) form of one label, or nil if it isn't acceptable.
    ///
    /// There is no Unicode case mapping anywhere: only ASCII letters are
    /// lowercased, so every comparison downstream is on ASCII ACE strings.
    /// - An ASCII label is used as is (ASCII-lowercased). An `xn--` label is
    ///   not rewritten, but must decode to a valid non-ASCII label that encodes
    ///   back to the identical label, else it is refused.
    /// - A non-ASCII label is NFC-normalised, checked and punycode-encoded.
    static func asciiLabel(_ label: String) -> String? {
        let lower = asciiLowercased(label)
        guard lower.utf8.allSatisfy({ $0 < 0x80 }) else { return encodeUnicodeLabel(lower) }
        guard lower.hasPrefix(acePrefix) else { return lower }
        return isStableACELabel(lower) ? lower : nil
    }

    /// Lowercases `A`–`Z` only. Foundation or Swift Unicode case mapping would
    /// turn one ACE label into another (U+13A0 into U+AB70), so it is never used.
    static func asciiLowercased(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let isUpper = (0x41...0x5A).contains(scalar.value)
            scalars.append(isUpper ? Unicode.Scalar(scalar.value + 0x20)! : scalar)
        }
        return String(scalars)
    }

    /// An `xn--` label whose payload decodes to a valid non-ASCII label that re-encodes identically.
    private static func isStableACELabel(_ label: String) -> Bool {
        guard let decoded = decode(String(label.dropFirst(acePrefix.count))),
            decoded.unicodeScalars.contains(where: { $0.value >= 0x80 }),
            decoded == decoded.precomposedStringWithCanonicalMapping, isAcceptableUnicodeLabel(decoded),
            let encoded = encode(decoded)
        else { return false }
        return acePrefix + encoded == label
    }

    /// `xn--` form of a Unicode label (ASCII already lowercased); nil if it fails validation.
    private static func encodeUnicodeLabel(_ lowered: String) -> String? {
        let nfc = lowered.precomposedStringWithCanonicalMapping
        guard isAcceptableUnicodeLabel(nfc), let encoded = encode(nfc) else { return nil }
        let label = acePrefix + encoded
        return label.utf8.count <= maxLabelLength ? label : nil
    }

    private static func isAcceptableUnicodeLabel(_ nfc: String) -> Bool {
        nfc == nfc.precomposedStringWithCompatibilityMapping && isValidUnicodeLabel(nfc)
    }

    /// Letters, marks and digits only (plus `-` not at either end). No symbols,
    /// punctuation, spaces, format controls (ZWJ, bidi marks) or label separators.
    private static func isValidUnicodeLabel(_ label: String) -> Bool {
        let scalars = Array(label.unicodeScalars)
        guard let first = scalars.first, let last = scalars.last, first != "-", last != "-" else { return false }
        if isMark(first) { return false }
        return scalars.allSatisfy { $0 == "-" || isLetterMarkOrDigit($0) }
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    private static func isLetterMarkOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .lowercaseLetter, .uppercaseLetter, .titlecaseLetter, .otherLetter, .modifierLetter, .nonspacingMark, .spacingMark, .decimalNumber: true
        default: false
        }
    }

    // MARK: - Punycode (RFC 3492)

    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700, initialBias = 72, initialN = 128

    private static func adapt(_ delta: Int, _ points: Int, first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / points
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }

    private static func digit(_ value: Int) -> Character {
        Character(Unicode.Scalar(UInt8(value < 26 ? 97 + value : 22 + value)))
    }

    private static func value(of byte: UInt8) -> Int? {
        switch byte {
        case 48...57: Int(byte) - 22
        case 97...122: Int(byte) - 97
        case 65...90: Int(byte) - 65
        default: nil
        }
    }

    private static func threshold(_ k: Int, _ bias: Int) -> Int { k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias) }

    static func encode(_ input: String) -> String? {
        let scalars = input.unicodeScalars.map { Int($0.value) }
        var output = String(String.UnicodeScalarView(input.unicodeScalars.filter { $0.value < 0x80 }))
        let basicCount = output.unicodeScalars.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }
        var n = initialN, delta = 0, bias = initialBias
        while handled < scalars.count {
            guard let m = scalars.filter({ $0 >= n }).min() else { return nil }
            let (grown, overflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            guard !overflow else { return nil }
            delta += grown
            n = m
            for scalar in scalars {
                if scalar < n { delta += 1 }
                guard scalar == n else { continue }
                var q = delta, k = base
                while true {
                    let t = threshold(k, bias)
                    if q < t { break }
                    output.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digit(q))
                bias = adapt(delta, handled + 1, first: handled == basicCount)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return output
    }

    static func decode(_ input: String) -> String? {
        let bytes = Array(input.utf8)
        guard bytes.allSatisfy({ $0 < 0x80 }), !bytes.isEmpty else { return nil }
        var output: [Int] = []
        var position = 0
        if let delimiter = bytes.lastIndex(of: UInt8(ascii: "-")) {
            output = bytes[..<delimiter].map(Int.init)
            position = delimiter + 1
        }
        var n = initialN, i = 0, bias = initialBias
        while position < bytes.count {
            let oldI = i
            var w = 1, k = base
            while true {
                guard position < bytes.count, let d = value(of: bytes[position]) else { return nil }
                position += 1
                let (gain, o1) = d.multipliedReportingOverflow(by: w)
                let (sum, o2) = i.addingReportingOverflow(gain)
                guard !o1, !o2 else { return nil }
                i = sum
                let t = threshold(k, bias)
                if d < t { break }
                let (next, o3) = w.multipliedReportingOverflow(by: base - t)
                guard !o3 else { return nil }
                w = next
                k += base
            }
            bias = adapt(i - oldI, output.count + 1, first: oldI == 0)
            let (grown, overflow) = n.addingReportingOverflow(i / (output.count + 1))
            guard !overflow else { return nil }
            n = grown
            i %= output.count + 1
            guard n <= 0x10FFFF else { return nil }
            output.insert(n, at: i)
            i += 1
        }
        var result = String.UnicodeScalarView()
        for value in output {
            guard let scalar = Unicode.Scalar(UInt32(value)) else { return nil }
            result.append(scalar)
        }
        return String(result)
    }
}
