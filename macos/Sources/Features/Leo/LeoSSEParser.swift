import Foundation

/// One dispatched Server-Sent-Event.
struct SSEEvent: Equatable, Sendable {
    let name: String?
    let data: String
    let id: String?
}

/// Pure incremental Server-Sent-Events parser (a subset of the WHATWG EventSource
/// spec sufficient for Leo's daemon: `event:`/`data:`/`id:` fields, blank-line
/// dispatch, `:`-prefixed comment lines used as heartbeats, multi-line `data:`
/// joined with `\n`). Feed raw byte chunks as they arrive — chunk boundaries may
/// fall mid-line or mid-field; buffering is byte-based so this never corrupts a
/// UTF-8 sequence split across chunks. Both `\n` and `\r\n` line endings are
/// accepted.
struct SSEParser {
    private var buffer = Data()
    private var eventName: String?
    private var dataLines: [String] = []
    private var lastID: String?

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    init() {}

    /// Feed a chunk of raw bytes and return any events fully dispatched as a
    /// result (zero, one, or several, depending on how many blank-line
    /// boundaries the chunk completes).
    mutating func feed(_ chunk: Data) -> [SSEEvent] {
        buffer.append(chunk)
        var events: [SSEEvent] = []
        while let newlineIndex = buffer.firstIndex(of: Self.lineFeed) {
            var lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if lineData.last == Self.carriageReturn {
                lineData = lineData.dropLast()
            }
            // `String(bytes:encoding:)` would return nil on invalid UTF-8 and
            // drop the line; `decoding:as:` instead substitutes the Unicode
            // replacement character, which keeps the parser resilient to a
            // stray malformed byte without losing synchronization on `\n`.
            let line = String(decoding: lineData, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
            if let event = process(line: line) {
                events.append(event)
            }
        }
        return events
    }

    /// Process a single complete line, dispatching an event on a blank line.
    private mutating func process(line: String) -> SSEEvent? {
        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return nil // comment / heartbeat, per spec
        }

        let (field, value) = Self.splitField(line)
        switch field {
        case "event":
            eventName = value
        case "data":
            dataLines.append(value)
        case "id":
            lastID = value
        default:
            break // unrecognized field, ignored per spec
        }
        return nil
    }

    /// Dispatch the currently-buffered event, if any `data:` lines were seen,
    /// then reset the per-event buffers for the next one.
    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventName = nil
            dataLines = []
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(name: eventName, data: dataLines.joined(separator: "\n"), id: lastID)
    }

    /// Split a `field: value` line. A single leading space after the colon
    /// is stripped, per spec; a line with no colon is treated as a
    /// field name with an empty value.
    private static func splitField(_ line: String) -> (field: String, value: String) {
        guard let colonIndex = line.firstIndex(of: ":") else {
            return (line, "")
        }
        let field = String(line[line.startIndex..<colonIndex])
        var value = String(line[line.index(after: colonIndex)...])
        if value.hasPrefix(" ") {
            value.removeFirst()
        }
        return (field, value)
    }
}
