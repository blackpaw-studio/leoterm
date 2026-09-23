import Darwin
import Foundation
import Testing

@testable import Ghostty

/// A `LeoSyntaxHighlighter.Matcher` that runs the same regex on ICU -- the
/// engine under `NSRegularExpression` -- directly, so it can count the
/// engine's work. ICU calls a match callback once every fixed number of
/// match steps (a "tick", about ten thousand), summed over the whole scan,
/// so `ticks` measures how much the regex did, not how long the machine
/// took to do it: a rule that re-scans a 4K line from every position costs
/// thousands of ticks, a one-pass rule next to none, whatever the load.
final class LeoRegexWorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var scanned = 0

    /// Engine ticks over every scan so far.
    var ticks: Int { lock.withLock { total } }
    /// Characters handed to the regex so far.
    var scannedCharacters: Int { lock.withLock { scanned } }

    var matcher: LeoSyntaxHighlighter.Matcher {
        { [self] regex, text, range in matches(regex, in: text, range: range) }
    }

    private func matches(_ regex: NSRegularExpression, in text: String, range: NSRange) -> [NSTextCheckingResult] {
        let icu: ICU
        switch ICU.loaded {
        case .success(let loaded): icu = loaded
        case .failure(let error):
            Issue.record("\(error)")
            return []
        }
        guard let flags = ICU.flags(for: regex.options) else {
            Issue.record("Unsupported regex options \(regex.options)")
            return []
        }
        let tally = Tally()
        var status: Int32 = 0
        let pattern = Array(regex.pattern.utf16)
        guard let handle = icu.open(pattern, Int32(pattern.count), flags, nil, &status), status <= 0 else {
            Issue.record("uregex_open failed (\(status)) for \(regex.pattern)")
            return []
        }
        defer { icu.close(handle) }
        let utf16 = Array(text.utf16)
        let results = utf16.withUnsafeBufferPointer { buffer -> [NSTextCheckingResult] in
            icu.setText(handle, buffer.baseAddress!, Int32(buffer.count), &status)
            icu.setRegion(handle, Int32(range.location), Int32(NSMaxRange(range)), &status)
            icu.setMatchCallback(handle, { context, _ in
                Unmanaged<Tally>.fromOpaque(context!).takeUnretainedValue().count += 1
                return 1
            }, Unmanaged.passUnretained(tally).toOpaque(), &status)
            let groups = Int(icu.groupCount(handle, &status))
            var results: [NSTextCheckingResult] = []
            while status <= 0, icu.findNext(handle, &status) != 0 {
                var ranges = (0...groups).map { group -> NSRange in
                    let start = Int(icu.start(handle, Int32(group), &status))
                    let end = Int(icu.end(handle, Int32(group), &status))
                    return start < 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: start, length: end - start)
                }
                results.append(NSTextCheckingResult.regularExpressionCheckingResult(
                    ranges: &ranges, count: ranges.count, regularExpression: regex
                ))
            }
            return results
        }
        if status > 0 { Issue.record("ICU matching failed (\(status)) for \(regex.pattern)") }
        withExtendedLifetime(tally) {
            lock.withLock {
                total += tally.count
                scanned += range.length
            }
        }
        return results
    }

    private final class Tally {
        var count = 0
    }
}

/// The few `uregex_*` entry points of the system's libicucore, loaded once.
/// A missing one is a recorded failure naming it, not a crash.
private struct ICU {
    typealias Handle = OpaquePointer
    typealias Callback = @convention(c) (UnsafeRawPointer?, Int32) -> Int8

    struct Missing: Error, CustomStringConvertible {
        let symbol: String
        var description: String { "libicucore lacks \(symbol)" }
    }

    static let loaded = Result { try ICU(library: dlopen("/usr/lib/libicucore.A.dylib", RTLD_NOW)) }

    let open: @convention(c) (UnsafePointer<UInt16>, Int32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>) -> Handle?
    let close: @convention(c) (Handle) -> Void
    let setText: @convention(c) (Handle, UnsafePointer<UInt16>, Int32, UnsafeMutablePointer<Int32>) -> Void
    let setRegion: @convention(c) (Handle, Int32, Int32, UnsafeMutablePointer<Int32>) -> Void
    let setMatchCallback: @convention(c) (Handle, Callback, UnsafeRawPointer?, UnsafeMutablePointer<Int32>) -> Void
    let groupCount: @convention(c) (Handle, UnsafeMutablePointer<Int32>) -> Int32
    let findNext: @convention(c) (Handle, UnsafeMutablePointer<Int32>) -> Int8
    let start: @convention(c) (Handle, Int32, UnsafeMutablePointer<Int32>) -> Int32
    let end: @convention(c) (Handle, Int32, UnsafeMutablePointer<Int32>) -> Int32

    private init(library: UnsafeMutableRawPointer?) throws {
        func symbol<T>(_ name: String) throws -> T {
            guard let library, let address = dlsym(library, name) else { throw Missing(symbol: name) }
            return unsafeBitCast(address, to: T.self)
        }
        open = try symbol("uregex_open")
        close = try symbol("uregex_close")
        setText = try symbol("uregex_setText")
        setRegion = try symbol("uregex_setRegion")
        setMatchCallback = try symbol("uregex_setMatchCallback")
        groupCount = try symbol("uregex_groupCount")
        findNext = try symbol("uregex_findNext")
        start = try symbol("uregex_start")
        end = try symbol("uregex_end")
    }

    /// `UREGEX_MULTILINE`; the highlighter uses no other option.
    static func flags(for options: NSRegularExpression.Options) -> UInt32? {
        switch options {
        case []: 0
        case .anchorsMatchLines: 8
        default: nil
        }
    }
}
