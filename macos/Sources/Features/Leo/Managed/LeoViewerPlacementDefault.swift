import Foundation

/// B-341: gives a managed `leo.yaml` with no dispatch viewer placement
/// `defaults.dispatch.viewer.placement: window`, so dispatch viewers open as
/// windows reached from the sidebar instead of splitting the caller's window.
///
/// Pure and conservative, like `LeoWebAPIDefault`: only the missing part of
/// the key path is added, as whole new lines, and every other byte stays as
/// it was. Any existing placement is `.present`; anything this scan can't be
/// sure of is `.skip`, so a user-authored config is never rewritten on a guess.
enum LeoViewerPlacementDefault: Equatable, Sendable {
    /// The whole new text.
    case insert(String)
    case present
    case skip(reason: String)

    static let placement = "window"
    static let path = ["defaults", "dispatch", "viewer", "placement"]
    /// The indent step when the file shows none to copy.
    static let defaultStep = 2

    static func migrate(yaml: String, pathKind: LeoPathKind) -> Self {
        guard pathKind == .file else { return .skip(reason: "leo.yaml isn’t a regular file") }
        guard !yaml.unicodeScalars.contains(where: otherLineBreaks.contains) else {
            return .skip(reason: "leo.yaml has line breaks other than \\n")
        }
        let byteOrderMark = yaml.hasPrefix(LeoYAMLKeyLine.byteOrderMark) ? LeoYAMLKeyLine.byteOrderMark : ""
        let texts = LeoYAMLKeyLine.droppingByteOrderMark(yaml)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        do {
            guard let found = try insertion(into: texts.map(Line.init)) else { return .present }
            let lines = Array(texts[..<found.at]) + found.lines + Array(texts[found.at...])
            return .insert(byteOrderMark + lines.joined(separator: "\n"))
        } catch let skip as Skip {
            return .skip(reason: skip.reason)
        } catch {
            return .skip(reason: "\(error)")
        }
    }

    /// YAML parsers also break lines at these; a scan that splits only at
    /// `\n` could misread the file.
    private static let otherLineBreaks: Set<Unicode.Scalar> = ["\r", "\u{85}", "\u{2028}", "\u{2029}"]

    // MARK: the scan

    /// The lines to add and where, or nil when the placement is already set.
    private static func insertion(into lines: [Line]) throws -> (lines: [String], at: Int)? {
        var level = try Level(lines, documentBody(lines))
        guard try level.entry(named: "follow") == nil else {
            throw Skip("leo.yaml follows a lead host, whose shared config may set the placement")
        }
        var step = level.firstStep(lines) ?? defaultStep
        var parent: Level.Entry?
        for (depth, name) in path.enumerated() {
            try level.rejectMergesAndAnchors()
            guard let entry = try level.entry(named: name) else {
                // Under the parent's key line, or before the first top-level key: never after a value.
                let indent = level.indent ?? parent.map { $0.indent + step } ?? 0
                let index = parent.map { $0.line + 1 } ?? level.entries.first?.line ?? end(of: lines)
                return (added(path[depth...], indent: indent, step: step), index)
            }
            if depth == path.count - 1 { return nil }
            guard entry.hasNoValue else {
                throw Skip("leo.yaml’s \(path[...depth].joined(separator: ".")) isn’t a block mapping")
            }
            let child = try Level(lines, level.block(of: entry))
            if let indent = child.indent { step = indent - entry.indent }
            parent = entry
            level = child
        }
        return nil
    }

    /// The lines after a leading `---`; any other document marker is a skip.
    private static func documentBody(_ lines: [Line]) throws -> Range<Int> {
        let first = lines.firstIndex { !$0.isTrivia }
        let start = first.map { lines[$0].text == "---" ? $0 + 1 : 0 } ?? 0
        guard !lines[start...].contains(where: { LeoYAMLKeyLine.isDocumentMarker($0.text) }) else {
            throw Skip("leo.yaml has more than one YAML document")
        }
        return start..<lines.count
    }

    /// Before the trailing newline's empty last line, if any.
    private static func end(of lines: [Line]) -> Int {
        lines.last?.text.isEmpty == true ? lines.count - 1 : lines.count
    }

    private static func added(_ names: ArraySlice<String>, indent: Int, step: Int) -> [String] {
        names.enumerated().map { offset, name in
            let value = name == path.last ? " \(placement)" : ""
            return String(repeating: " ", count: indent + offset * step) + name + ":" + value
        }
    }

    private struct Skip: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    private struct Line {
        let text: String
        let scalars: [Unicode.Scalar]
        /// Leading spaces; YAML never indents with tabs.
        let indent: Int
        /// Blank or a comment.
        let isTrivia: Bool

        init(_ text: String) {
            self.text = text
            scalars = Array(text.unicodeScalars)
            indent = scalars.prefix(while: { $0 == " " }).count
            let content = scalars.drop(while: { $0 == " " || $0 == "\t" })
            isTrivia = content.first.map { $0 == "#" } ?? true
        }

        var hasTabIndent: Bool { scalars.dropFirst(indent).first == "\t" }
    }

    /// One block mapping's entries: the lines at its column. Deeper lines
    /// belong to the entry above them and aren't read.
    private struct Level {
        struct Entry {
            let key: [Unicode.Scalar]
            let value: ArraySlice<Unicode.Scalar>
            let line: Int
            let indent: Int

            func isNamed(_ name: String) -> Bool { key.elementsEqual(name.unicodeScalars) }
            /// Nothing after the colon but maybe a comment.
            var hasNoValue: Bool { value.first.map { $0 == "#" } ?? true }
        }

        /// The entries' column; nil when the block holds no entries.
        let indent: Int?
        let entries: [Entry]
        let end: Int

        init(_ lines: [Line], _ range: Range<Int>) throws {
            var indent: Int?
            var entries: [Entry] = []
            for index in range where !lines[index].isTrivia {
                let line = lines[index]
                let column = indent ?? line.indent
                indent = column
                if line.indent > column { continue }
                guard line.indent == column, !line.hasTabIndent else { throw Skip("leo.yaml’s indentation is ambiguous") }
                guard let pair = LeoYAMLKeyLine.keyValue(line.scalars[column...]) else {
                    throw Skip("leo.yaml has a line that isn’t a plain `key:` where a mapping is needed")
                }
                entries.append(Entry(key: pair.key, value: pair.value, line: index, indent: column))
            }
            self.indent = indent
            self.entries = entries
            end = range.upperBound
        }

        func entry(named name: String) throws -> Entry? {
            let matches = entries.filter { $0.isNamed(name) }
            guard matches.count < 2 else { throw Skip("leo.yaml repeats the key “\(name)”") }
            return matches.first
        }

        /// A merge key may bring in the path; an anchor or alias may share it.
        func rejectMergesAndAnchors() throws {
            guard !entries.contains(where: { $0.isNamed("<<") }) else { throw Skip("leo.yaml uses a YAML merge key") }
            guard !entries.contains(where: { $0.value.first == "&" || $0.value.first == "*" }) else {
                throw Skip("leo.yaml uses YAML anchors or aliases")
            }
        }

        func block(of entry: Entry) -> Range<Int> {
            (entry.line + 1)..<(entries.first { $0.line > entry.line }?.line ?? end)
        }

        /// The indent step of the first entry with indented lines under it.
        func firstStep(_ lines: [Line]) -> Int? {
            entries.lazy.compactMap { entry in
                self.block(of: entry).first { !lines[$0].isTrivia }.map { lines[$0].indent - entry.indent }
            }.first { $0 > 0 }
        }
    }
}
