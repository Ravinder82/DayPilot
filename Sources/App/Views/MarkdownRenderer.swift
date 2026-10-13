import Foundation

/// A parsed Markdown document: blocks of structure, with inline runs inside them.
///
/// `AttributedString(markdown:)` does not expose the structure the debrief needs,
/// namely fenced code blocks and tables as separate blocks that carry their own
/// copy actions, so the debrief is parsed here. The parser is pure, and it never
/// traps or stalls on input: every index is checked before it is used, and every
/// block consumes at least one line.
struct MarkdownDocument: Equatable {

    enum Block: Equatable {
        case heading(level: Int, inline: [Inline])
        case paragraph(inline: [Inline])
        case codeBlock(language: String, code: String)
        case bulletList(items: [[Block]])
        case numberedList(items: [[Block]])
        case quote(children: [Block])
        case divider
        case table(headers: [String], rows: [[String]])
    }

    enum Inline: Equatable {
        case text(String)
        case bold([Inline])
        case italic([Inline])
        case code(String)
        case link(String, URL?)
    }

    let blocks: [Block]

    init(blocks: [Block]) {
        self.blocks = blocks
    }

    init(markdown: String) {
        self.blocks = MarkdownParser.parse(markdown)
    }
}

// MARK: - Parser

enum MarkdownParser {

    static func parse(_ source: String) -> [MarkdownDocument.Block] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var blocks: [MarkdownDocument.Block] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let fence = openingFence(line) {
                let parsed = readCodeBlock(lines: lines, start: index, fence: fence)
                blocks.append(parsed.block)
                index = parsed.next
                continue
            }

            if let heading = readHeading(line) {
                blocks.append(heading)
                index += 1
                continue
            }

            if isDivider(line) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if line.hasPrefix(">") {
                let parsed = readQuote(lines: lines, start: index)
                blocks.append(parsed.block)
                index = parsed.next
                continue
            }

            if let table = readTable(lines: lines, start: index) {
                blocks.append(table.block)
                index = table.next
                continue
            }

            if let list = readList(lines: lines, start: index, ordered: false) {
                blocks.append(list.block)
                index = list.next
                continue
            }

            if let list = readList(lines: lines, start: index, ordered: true) {
                blocks.append(list.block)
                index = list.next
                continue
            }

            let paragraph = readParagraph(lines: lines, start: index)
            blocks.append(paragraph.block)
            index = paragraph.next
        }

        return blocks
    }

    // MARK: Blocks

    private static func openingFence(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        return String(trimmed.prefix(3))
    }

    private static func readCodeBlock(
        lines: [String],
        start: Int,
        fence: String
    ) -> (block: MarkdownDocument.Block, next: Int) {
        let opening = lines[start].trimmingCharacters(in: .whitespaces)
        let language = String(opening.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)

        var collected: [String] = []
        var index = start + 1

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fence) {
                return (.codeBlock(language: language, code: collected.joined(separator: "\n")), index + 1)
            }
            collected.append(lines[index])
            index += 1
        }

        // An unterminated fence still renders. Swallowing the rest of the
        // document would be worse than showing the code as it stands.
        return (.codeBlock(language: language, code: collected.joined(separator: "\n")), index)
    }

    private static func readHeading(_ line: String) -> MarkdownDocument.Block? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }

        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard level > 0, level <= 6 else { return nil }

        var title = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        // A closing run of hashes is decoration, not part of the title.
        if title.hasSuffix("#") {
            title = String(title.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return .heading(level: level, inline: parseInline(title))
    }

    private static func isDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let characters = Set(trimmed)
        guard characters.count == 1, let only = characters.first else { return false }
        return only == "-" || only == "*" || only == "_"
    }

    private static func readQuote(
        lines: [String],
        start: Int
    ) -> (block: MarkdownDocument.Block, next: Int) {
        var collected: [String] = []
        var index = start

        while index < lines.count, lines[index].hasPrefix(">") {
            collected.append(String(lines[index].dropFirst()).trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return (.quote(children: parse(collected.joined(separator: "\n"))), index)
    }

    private static func readTable(
        lines: [String],
        start: Int
    ) -> (block: MarkdownDocument.Block, next: Int)? {
        let headerLine = lines[start]
        guard headerLine.contains("|"), start + 1 < lines.count else { return nil }

        let separator = lines[start + 1].trimmingCharacters(in: .whitespaces)
        guard separator.contains("|"), separator.contains("-"),
              Set(separator.filter { $0 != "|" && $0 != " " && $0 != ":" }) == ["-"] else {
            return nil
        }

        func cells(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|") { trimmed.removeLast() }
            return trimmed
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }

        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count, lines[index].contains("|") {
            rows.append(cells(lines[index]))
            index += 1
        }
        return (.table(headers: cells(headerLine), rows: rows), index)
    }

    private static func readList(
        lines: [String],
        start: Int,
        ordered: Bool
    ) -> (block: MarkdownDocument.Block, next: Int)? {
        var items: [[MarkdownDocument.Block]] = []
        var index = start

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            let markerLength: Int
            if ordered {
                guard let marker = trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) else { break }
                markerLength = trimmed.distance(from: marker.lowerBound, to: marker.upperBound)
            } else {
                guard unorderedMarker(trimmed) else { break }
                markerLength = 2
            }

            var itemLines = [String(trimmed.dropFirst(markerLength))]
            var next = index + 1

            while next < lines.count {
                let candidate = lines[next]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)

                if candidateTrimmed.isEmpty {
                    // A blank line ends the item unless the next non-blank line is
                    // indented under it, which makes it a lazy continuation.
                    let following = next + 1 < lines.count ? lines[next + 1] : ""
                    let followingIsIndented = following.prefix(while: { $0 == " " || $0 == "\t" }).count > 0
                    if followingIsIndented, !following.trimmingCharacters(in: .whitespaces).isEmpty {
                        itemLines.append("")
                        next += 1
                        continue
                    }
                    break
                }

                let candidateIndent = candidate.prefix(while: { $0 == " " || $0 == "\t" }).count
                if candidateIndent >= 2 {
                    itemLines.append(String(candidate.dropFirst(min(candidateIndent, 4))))
                    next += 1
                    continue
                }

                // A new marker, of either kind, starts the next item.
                if isOrderedMarker(candidateTrimmed) || unorderedMarker(candidateTrimmed) {
                    break
                }
                itemLines.append(candidateTrimmed)
                next += 1
            }

            items.append(parse(itemLines.joined(separator: "\n")))
            index = next
        }

        guard !items.isEmpty else { return nil }
        let block: MarkdownDocument.Block = ordered ? .numberedList(items: items) : .bulletList(items: items)
        return (block, index)
    }

    /// Always consumes its first line. `parse` only reaches this when no other
    /// block claimed the line, so taking it unconditionally is what guarantees the
    /// parser advances, even on a line such as `Stickies | Chrome` that looks like a
    /// table but is not one.
    private static func readParagraph(
        lines: [String],
        start: Int
    ) -> (block: MarkdownDocument.Block, next: Int) {
        var collected: [String] = [lines[start]]
        var index = start + 1

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { break }
            if openingFence(line) != nil { break }
            if trimmed.hasPrefix("#") { break }
            if isDivider(line) { break }
            if line.hasPrefix(">") { break }
            if line.contains("|") { break }
            if isOrderedMarker(trimmed) || unorderedMarker(trimmed) { break }

            collected.append(line)
            index += 1
        }

        return (.paragraph(inline: parseInline(collected.joined(separator: " "))), index)
    }

    private static func isOrderedMarker(_ trimmed: String) -> Bool {
        trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
    }

    private static func unorderedMarker(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
    }

    // MARK: Inline

    /// Parses emphasis, code spans and links.
    ///
    /// Hand-written rather than regex-driven so nesting is handled correctly, and
    /// so an unmatched delimiter degrades to literal text instead of consuming the
    /// rest of the line. Every range it forms has its bounds checked first.
    static func parseInline(_ text: String) -> [MarkdownDocument.Inline] {
        var result: [MarkdownDocument.Inline] = []
        var buffer = ""
        var index = text.startIndex

        func flush() {
            if !buffer.isEmpty {
                result.append(.text(buffer))
                buffer = ""
            }
        }

        while index < text.endIndex {
            let character = text[index]

            // Code spans come first: emphasis markers inside backticks are literal.
            if character == "`" {
                let contentStart = text.index(after: index)
                if let end = text[contentStart...].firstIndex(of: "`") {
                    flush()
                    result.append(.code(String(text[contentStart..<end])))
                    index = text.index(after: end)
                    continue
                }
            }

            // Links: [label](target). The label starts after "[", so its range is
            // always ordered.
            if character == "[",
               let close = text[index...].firstIndex(of: "]"),
               text.index(after: close) < text.endIndex,
               text[text.index(after: close)] == "(",
               let targetEnd = text[close...].firstIndex(of: ")") {
                let label = String(text[text.index(after: index)..<close])
                let targetStart = text.index(close, offsetBy: 2)
                let target = String(text[targetStart..<targetEnd])
                flush()
                result.append(.link(label, URL(string: target)))
                index = text.index(after: targetEnd)
                continue
            }

            // Emphasis. An underscore between letters is part of an identifier, such
            // as session_events or user_memory, so it only opens emphasis at a word
            // boundary.
            if character == "*" || character == "_", !isIntrawordUnderscore(text, at: index) {
                let delimiter = character
                let afterOpener = text.index(after: index)

                // Bold: a doubled delimiter with its closing pair after the opener.
                let pair = String(repeating: delimiter, count: 2)
                if text[index...].hasPrefix(pair) {
                    let contentStart = text.index(index, offsetBy: 2)
                    if let closing = text[contentStart...].range(of: pair) {
                        flush()
                        result.append(.bold(parseInline(String(text[contentStart..<closing.lowerBound]))))
                        index = closing.upperBound
                        continue
                    }
                }

                // Italic: a single delimiter with its closing twin after the opener.
                // The search starts after the opener. Starting at the opener finds
                // the opener itself and yields an inverted, invalid range.
                if afterOpener < text.endIndex,
                   let closing = text[afterOpener...].firstIndex(of: delimiter),
                   closing > afterOpener {
                    flush()
                    result.append(.italic(parseInline(String(text[afterOpener..<closing]))))
                    index = text.index(after: closing)
                    continue
                }
            }

            buffer.append(character)
            index = text.index(after: index)
        }

        flush()
        return result
    }

    private static func isIntrawordUnderscore(_ text: String, at index: String.Index) -> Bool {
        guard text[index] == "_", index > text.startIndex else { return false }
        let previous = text[text.index(before: index)]
        return previous.isLetter || previous.isNumber
    }
}
