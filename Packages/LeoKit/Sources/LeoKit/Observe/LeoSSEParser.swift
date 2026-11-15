import Foundation

public struct LeoSSEEvent: Equatable, Sendable {
    public let name: String?
    public let data: String
    public let id: String?

    public init(name: String?, data: String, id: String? = nil) {
        self.name = name
        self.data = data
        self.id = id
    }
}

public struct LeoSSEParser: Sendable {
    public init() {}

    private var buffer = Data()
    private var name: String?
    private var dataLines: [String] = []
    private var id: String?

    public mutating func feed(_ chunk: Data) -> [LeoSSEEvent] {
        buffer.append(chunk)
        var events: [LeoSSEEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line = line.dropLast() }
            guard let text = String(data: line, encoding: .utf8) else { continue }
            if let event = process(text) { events.append(event) }
        }
        return events
    }

    private mutating func process(_ line: String) -> LeoSSEEvent? {
        if line.isEmpty {
            defer { name = nil; dataLines = [] }
            guard !dataLines.isEmpty else { return nil }
            return LeoSSEEvent(name: name, data: dataLines.joined(separator: "\n"), id: id)
        }
        guard !line.hasPrefix(":") else { return nil }
        let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(pieces[0])
        var value = pieces.count == 2 ? String(pieces[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "event": name = value
        case "data": dataLines.append(value)
        case "id": id = value
        default: break
        }
        return nil
    }
}
