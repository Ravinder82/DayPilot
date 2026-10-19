import Foundation
import os

/// Deterministic clean-up pass over the model's brief.
///
/// The prompt forbids slop; this file guarantees it. Pompous and canned
/// phrases are dropped sentence-by-sentence, emoji are stripped, sections
/// that carry no content are removed rather than shipped as "Nothing
/// captured" filler, and — most importantly — every inline `code` artifact is
/// checked against the actual session payload, so an invented file path or
/// command can never reach the user's desk.
enum BriefSanitizer {

    private static let logger = Logger(subsystem: AppInfo.identifier, category: "sanitizer")

    // MARK: - Entry

    /// Returns the cleaned brief. `payloadCorpus` is the exact JSON that was
    /// sent to the model — the only universe of facts the brief may quote.
    static func sanitize(
        reportMarkdown: String,
        payloadCorpus: String,
        date: Date
    ) -> String {
        var removed: [String] = []

        var text = stripVoiceBlocks(reportMarkdown)
        text = substituteSoftSlop(text)
        text = normalizeTypography(text)
        text = scrubBannedSentences(in: text, removed: &removed)
        text = tameBold(text)
        text = stripHeadingDecoration(text)

        var sections = splitSections(text)
        sections = dropLegacySections(sections, removed: &removed)
        sections = dropEmptySections(sections, removed: &removed)
        sections = verifyArtifacts(in: sections, corpus: payloadCorpus.lowercased(), removed: &removed)
        text = join(sections)

        text = canonicalizeTitle(in: text, date: date)
        text = tidyWhitespace(text)

        if !removed.isEmpty {
            logger.notice("Brief sanitizer removed \(removed.count) item(s): \(removed.joined(separator: " · "), privacy: .public)")
        }
        return text
    }

    // MARK: - Voice script block (retired feature)

    private static func stripVoiceBlocks(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\[VOICE_SCRIPT\\][\\s\\S]*?\\[/VOICE_SCRIPT\\]") else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: - Typography

    /// Strips emoji and pictographs anywhere in the document, and collapses
    /// the double spaces they leave behind on prose lines (never inside code
    /// fences, where spacing is content).
    private static func normalizeTypography(_ text: String) -> String {
        var inFence = false
        var lines: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine
            let trimmedStart = line.trimmingCharacters(in: .whitespaces)
            if trimmedStart.hasPrefix("```") { inFence.toggle() }

            let stripped = String(String.UnicodeScalarView(line.unicodeScalars.filter { !isEmoji($0) }))
            if inFence {
                lines.append(stripped)
            } else {
                var collapsed = stripped
                while collapsed.contains("  ") {
                    collapsed = collapsed.replacingOccurrences(of: "  ", with: " ")
                }
                lines.append(collapsed)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1F000...0x1FAFF,   // symbols, pictographs, faces, supplemental
             0x2600...0x27BF,     // misc symbols, dingbats (⚡✅❌ etc.)
             0x2B00...0x2BFF,     // arrows/stars used as decoration
             0x23E9...0x23FA,     // media controls
             0x23F0...0x23F3,     // clocks/timers
             0xFE00...0xFE0F,     // variation selectors
             0x200D,              // zero-width joiner
             0x20E3,              // combining enclosing keycap
             0x24C2,              // circled M
             0x25AA...0x25AB,
             0x25FB...0x25FE:
            return true
        default:
            return false
        }
    }

    // MARK: - Heading decoration (the editor's pass)

    /// Headings are structure, not decoration.
    ///
    /// A template — or a model imitating one — leaves `### 2. 🧲 Rescued Assets
    /// (The Harvester)` behind: a stage number, an icon, a nickname. None of it
    /// survives a commercial edit, so it is removed here whatever the prompt
    /// asked for and the heading ships as `### Rescued Assets`. Lines inside a
    /// code fence are content, never headings, and are left untouched.
    private static func stripHeadingDecoration(_ text: String) -> String {
        var inFence = false
        var lines: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmedStart = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmedStart.hasPrefix("```") { inFence.toggle() }
            guard !inFence, trimmedStart.hasPrefix("#") else {
                lines.append(rawLine)
                continue
            }

            let hashes = rawLine.prefix(while: { $0 == "#" })
            var body = String(rawLine.dropFirst(hashes.count))
            body = String(body.drop(while: { $0 == " " }))

            // Stage numbering: "1. " or "2) ".
            if let number = body.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) {
                body = String(body[number.upperBound...])
            }
            // The nickname in parentheses that names the stage.
            if let nickname = body.range(of: #"\s*\([^()]*\)\s*$"#, options: .regularExpression) {
                body = String(body[..<nickname.lowerBound])
            }

            body = body.trimmingCharacters(in: .whitespaces)
            lines.append(body.isEmpty ? String(hashes) : "\(hashes) \(body)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Slop substitution (soft)

    /// Word-level swaps applied before the hard scrub. Only unambiguous,
    /// meaning-preserving replacements live here.
    private static func substituteSoftSlop(_ text: String) -> String {
        let replacements: [(String, String)] = [
            ("leverage", "use"), ("Leverage", "Use"),
            ("leveraging", "using"), ("Leveraging", "Using"),
            ("leveraged", "used"), ("Leveraged", "Used"),
            ("utilize", "use"), ("Utilize", "Use"),
            ("utilizing", "using"), ("Utilizing", "Using"),
            ("utilised", "used"), ("utilized", "used"),
            ("in order to", "to"), ("In order to", "To"),
            ("prior to", "before"), ("Prior to", "Before"),
            ("a myriad of", "many"), ("a plethora of", "many"),
            ("truly ", ""), ("Truly ", ""),
            ("genuinely ", ""), ("Genuinely ", ""),
            ("really ", ""), ("Really ", ""),
            ("very ", ""), ("Very ", "")
        ]

        var inFence = false
        var lines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmedStart = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmedStart.hasPrefix("```") { inFence.toggle() }
            if inFence {
                lines.append(rawLine)
            } else {
                var line = rawLine
                for (from, to) in replacements {
                    line = line.replacingOccurrences(of: from, with: to)
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Banned phrases (hard)

    /// Phrases a chief of staff would never write. A sentence containing any
    /// of these is removed outright — they are unambiguous tells.
    private static let bannedPhrases: [String] = [
        // Verbs / adjectives that mark machine writing.
        "delve", "game-chang", "testament to", "unlock the", "unlock your",
        "elevate your", "elevate the", "seamless", "supercharge", "turbocharge",
        "revolutioniz", "revolutionis", "transformative", "embark on",
        "dive into", "deep dive", "cutting-edge", "state-of-the-art",
        "world-class", "best-in-class", "showcase", "underscore", "pivotal",
        "holistic", "multifaceted", "meticulous", "invaluable", "beacon",
        "cornerstone", "catalyst", "paradigm", "myriad", "bustling", "vibrant",
        "heartfelt", "thrilling", "impactful", "ever-evolving",
        // Phrases.
        "in today's fast-paced", "navigate the complexities", "navigating the",
        "landscape of", "realm of", "tapestry", "synergy", "harness",
        "empower", "foster a", "when it comes to", "plays a crucial",
        "plays a vital", "here's the thing", "let's unpack", "onward and upward",
        "the road ahead", "not only", "at its core", "take a moment",
        "celebrate the win", "positions us well", "quietly powerful",
        "to sum up", "summarizing", "it's not just", "isn't just",
        "not just about", "the real magic", "secret sauce", "level up",
        "next level", "kudos", "great job", "keep it up", "you crushed",
        "proud of you", "remember to ", "don't forget", "make sure you",
        "make sure to", "circle back", "touch base", "low-hanging fruit",
        "actionable insight", "key takeaway", "why it matters",
        "it's worth noting", "it should be noted", "in conclusion",
        "frictionless", "effortless", "on this journey", "your journey",
        "the bottom line is"
    ]

    /// Sentence-opening connectors that read as generated filler.
    private static let bannedOpeners: [String] = [
        "moreover", "furthermore", "additionally", "ultimately",
        "in summary", "to summarize", "overall", "that said"
    ]

    private static func scrubBannedSentences(in text: String, removed: inout [String]) -> String {
        var inFence = false
        var output: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmedStart = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmedStart.hasPrefix("```") {
                inFence.toggle()
                output.append(rawLine)
                continue
            }
            if inFence || trimmedStart.hasPrefix("#") || trimmedStart.isEmpty {
                output.append(rawLine)
                continue
            }

            // Keep list markers/section labels intact while scrubbing the prose.
            let prefix = listPrefix(of: rawLine)
            let body = String(rawLine.dropFirst(prefix.count))
            let sentences = splitSentences(body)

            var kept: [String] = []
            for sentence in sentences {
                let lowered = sentence.lowercased()
                let firstWord = lowered
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: " ", maxSplits: 1)
                    .first
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.:;")) } ?? ""

                if bannedPhrases.contains(where: { lowered.contains($0) })
                    || bannedOpeners.contains(firstWord) {
                    removed.append("slop: \(sentence.trimmingCharacters(in: .whitespaces).prefix(60))…")
                } else {
                    kept.append(sentence)
                }
            }

            let rebuilt = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if rebuilt.isEmpty {
                // The whole line was slop; drop it.
                continue
            }
            output.append(prefix.isEmpty ? rebuilt : prefix + rebuilt)
        }
        return output.joined(separator: "\n")
    }

    // MARK: - Emphasis discipline

    /// Bold is a tool, not a texture. Headings never carry it, and a line with
    /// more than two bold runs loses all of them — that pattern reads as
    /// machine-made emphasis.
    private static func tameBold(_ text: String) -> String {
        var inFence = false
        var lines: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmedStart = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmedStart.hasPrefix("```") {
                inFence.toggle()
                lines.append(rawLine)
                continue
            }
            if inFence {
                lines.append(rawLine)
                continue
            }

            var line = rawLine
            if trimmedStart.hasPrefix("#") {
                line = line.replacingOccurrences(of: "**", with: "")
            } else {
                let boldMarks = line.components(separatedBy: "**").count - 1
                if boldMarks > 4 {
                    line = line.replacingOccurrences(of: "**", with: "")
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Sections

    private struct Section {
        var heading: String?           // the raw heading line, when it has one
        var lines: [String]
    }

    private static func splitSections(_ text: String) -> [Section] {
        var sections: [Section] = []
        var current = Section(heading: nil, lines: [])
        let headingRegex = try? NSRegularExpression(pattern: "^#{1,6} ")

        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            let isHeading = headingRegex?.firstMatch(in: line, range: range) != nil
            if isHeading {
                if current.heading != nil || !current.lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    sections.append(current)
                }
                current = Section(heading: line, lines: [])
            } else {
                current.lines.append(line)
            }
        }
        sections.append(current)
        return sections
    }

    private static func join(_ sections: [Section]) -> String {
        sections
            .map { ($0.heading.map { [$0] } ?? []) + $0.lines }
            .flatMap { $0 }
            .joined(separator: "\n")
    }

    /// Sections the app owns (provenance, voice script, profile notes) must
    /// never be duplicated by the model inside its own output.
    private static func dropLegacySections(_ sections: [Section], removed: inout [String]) -> [Section] {
        let legacy: [String] = [
            "voice script", "rules of thumb", "provenance", "audit",
            "metadata", "generated by"
        ]
        return sections.filter { section in
            guard let heading = section.heading else { return true }
            let lowered = heading.lowercased()
            if legacy.contains(where: { lowered.contains($0) }) {
                removed.append("legacy section: \(heading)")
                return false
            }
            return true
        }
    }

    private static func dropEmptySections(_ sections: [Section], removed: inout [String]) -> [Section] {
        sections.filter { section in
            guard let heading = section.heading else { return true }

            var contentWords = 0
            for line in section.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !isFillerLine(trimmed) else { continue }
                contentWords += trimmed.split(separator: " ").count
            }
            if contentWords < 3 {
                removed.append("empty section: \(heading)")
                return false
            }
            return true
        }
    }

    /// A line that says nothing: "Nothing shipped in this session.",
    /// "No logs were captured.", "None." — short negative boilerplate.
    /// Bounded to short lines so a real sentence that merely starts with
    /// "Nothing" survives.
    private static func isFillerLine(_ line: String) -> Bool {
        let lowered = line
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_-—• \t"))
        let wordCount = lowered.split(separator: " ").count
        guard wordCount <= 15 else { return false }

        if lowered.isEmpty { return true }
        if lowered.hasPrefix("nothing") || lowered.hasPrefix("none") { return true }
        if lowered.hasPrefix("no ") || lowered.hasPrefix("not ") {
            let markers = [
                "captured", "recorded", "found", "detected", "shipped",
                "logged", "data", "report", "applicable", "pruned", "activity"
            ]
            if markers.contains(where: { lowered.contains($0) }) { return true }
        }
        return false
    }

    // MARK: - Artifact verification

    /// Any inline `code` token that looks like a path, file, URL, or command
    /// must exist somewhere in the session payload. Lines quoting invented
    /// artifacts are dropped; a fabricated "Tomorrow, first move" section is
    /// removed whole.
    private static func verifyArtifacts(in sections: [Section], corpus: String, removed: inout [String]) -> [Section] {
        let tokenRegex = try? NSRegularExpression(pattern: "`([^`\\n]+)`")

        return sections.compactMap { section in
            var kept: [String] = []
            var sectionFabricated = false

            for line in section.lines {
                let lineRange = NSRange(line.startIndex..., in: line)
                let matches = tokenRegex?.matches(in: line, range: lineRange) ?? []

                var failing: String?
                for match in matches {
                    guard match.numberOfRanges > 1,
                          let tokenRange = Range(match.range(at: 1), in: line) else { continue }
                    let token = String(line[tokenRange]).trimmingCharacters(in: .whitespaces)
                    guard looksLikeArtifact(token) else { continue }
                    if !corpusContains(token, corpus: corpus) {
                        failing = token
                        break
                    }
                }

                if let failing {
                    removed.append("unverified artifact: \(failing)")
                    if let heading = section.heading, isTomorrowSection(heading) {
                        sectionFabricated = true
                        break
                    }
                    continue // drop the line, keep the rest
                }
                kept.append(line)
            }

            if sectionFabricated {
                removed.append("section removed (fabricated move): \(section.heading ?? "")")
                return nil
            }
            var copy = section
            copy.lines = kept
            return copy
        }
    }

    private static func isTomorrowSection(_ heading: String) -> Bool {
        let lowered = heading.lowercased()
        return lowered.contains("tomorrow") || lowered.contains("first move") || lowered.contains("next")
    }

    private static func looksLikeArtifact(_ token: String) -> Bool {
        guard token.count >= 3, token.count <= 200 else { return false }
        if token.contains("://") { return true }
        if token.contains("/") { return true }

        let filePattern = try? NSRegularExpression(
            pattern: "^[\\w.\\-]+\\.(swift|ts|tsx|js|jsx|py|rb|go|rs|md|json|yml|yaml|toml|sh|zsh|kt|java|m|mm|cpp|c|h|hpp|plist|entitlements|xcodeproj|css|html|sql|txt)$",
            options: [.caseInsensitive]
        )
        if let filePattern {
            let range = NSRange(token.startIndex..., in: token)
            if filePattern.firstMatch(in: token, range: range) != nil { return true }
        }

        let commandPrefixes = [
            "open ", "git ", "swift ", "npm ", "pnpm ", "yarn ", "cd ", "make ",
            "xcodebuild ", "python ", "pip ", "cargo ", "go ", "docker ", "curl ", "brew "
        ]
        return commandPrefixes.contains { token.hasPrefix($0) }
    }

    /// The token may appear in the payload whole, or as the file name alone
    /// when the capture only ever showed the short form.
    private static func corpusContains(_ token: String, corpus: String) -> Bool {
        let lowered = token.lowercased()
        if corpus.contains(lowered) { return true }
        if let lastComponent = lowered.split(separator: "/").last, lastComponent.count >= 3 {
            if corpus.contains(String(lastComponent)) { return true }
        }
        return false
    }

    // MARK: - Title

    private static func canonicalizeTitle(in text: String, date: Date) -> String {
        let title = "# Day Brief — \(dayTitle(from: date))"
        var lines = text.components(separatedBy: .newlines)

        if let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let first = lines[firstIndex].trimmingCharacters(in: .whitespaces)
            // Only a top-level heading is the document title. Anything else —
            // a section heading left by the empty-section pass, or plain prose
            // — gets the canonical title inserted above it.
            let isTopLevelHeading = first == "#" || (first.hasPrefix("#") && !first.hasPrefix("##"))
            if isTopLevelHeading {
                lines[firstIndex] = title
            } else {
                lines.insert(contentsOf: [title, ""], at: firstIndex)
            }
        } else {
            lines = [title]
        }
        return lines.joined(separator: "\n")
    }

    static func dayTitle(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return formatter.string(from: date)
    }

    // MARK: - Whitespace

    private static func tidyWhitespace(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines).map { line -> String in
            var value = line
            while value.hasSuffix(" ") || value.hasSuffix("\t") { value.removeLast() }
            return value
        }

        // Collapse runs of blank lines to at most one.
        var collapsed: [String] = []
        var previousBlank = false
        for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank && previousBlank { continue }
            collapsed.append(line)
            previousBlank = isBlank
        }
        lines = collapsed

        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Text helpers

    private static func listPrefix(of line: String) -> String {
        let pattern = try? NSRegularExpression(pattern: "^(\\s*(?:[-*+]|\\d+\\.)\\s+)")
        guard let regex = pattern else { return "" }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let swiftRange = Range(match.range, in: line) else { return "" }
        return String(line[swiftRange])
    }

    /// Sentence split that keeps terminators; tolerant of abbreviations by
    /// only splitting on terminator + whitespace.
    private static func splitSentences(_ text: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: "(?<=[.!?])\\s+")
        guard let regex else { return [text] }
        let range = NSRange(text.startIndex..., in: text)
        var sentences: [String] = []
        var location = 0
        for match in regex.matches(in: text, range: range) {
            if let swiftRange = Range(NSRange(location: location, length: match.range.location - location), in: text) {
                sentences.append(String(text[swiftRange]))
            }
            location = match.range.location + match.range.length
        }
        if let tail = Range(NSRange(location: location, length: (text as NSString).length - location), in: text) {
            sentences.append(String(text[tail]))
        }
        return sentences.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
