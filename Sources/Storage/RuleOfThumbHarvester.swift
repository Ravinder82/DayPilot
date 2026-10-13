import Foundation

/// Pulls durable engineering lessons out of a generated debrief.
///
/// The profile's rules of thumb are the compounding asset: by day 30 they should
/// contain the lessons of 30 days of work. Extracting them automatically means
/// the user never has to maintain a notes file they will never open.
///
/// Extraction is deliberately conservative. A wrong rule pollutes every future
/// prompt, so the harvester throws away anything ambiguous rather than
/// guessing.
import Foundation

enum RuleOfThumbHarvester {

    /// Markers the prompt asks the model to attach a lesson to.
    private static let lessonMarkers = [
        "Friction & Strategic Lesson",
        "Strategic Lesson",
        "Rule of thumb",
        "Engineering takeaway",
        "Lesson:"
    ]

    /// Sentence openers that indicate an imperative rule.
    private static let imperativeStarters = ["Always ", "Never ", "Prefer ", "Avoid ", "Keep ", "Use "]

    /// Bounds on an acceptable rule: too short to be a lesson, too long to be
    /// quotable a year later.
    static let minimumLength = 40
    static let maximumLength = 240
    static let maximumRules = 5

    /// Extracts candidate rules from a debrief.
    ///
    /// Returns at most `maximumRules`, ordered by how confident the harvester
    /// is: lines explicitly marked as a lesson first, then imperative sentences
    /// found elsewhere.
    static func harvest(from report: String) -> [String] {
        var results: [String] = []
        var seen = Set<String>()

        for candidate in lessonCandidates(report) + imperativeCandidates(report) {
            let cleaned = clean(candidate)
            guard isAcceptable(cleaned) else { continue }
            let key = cleaned.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(cleaned)
            if results.count == maximumRules { break }
        }
        return results
    }

    // MARK: - Candidates

    /// Text after the colon on a lesson-marked line.
    ///
    /// The prompt asks for `* **Friction & Strategic Lesson:** <lesson>`, so the
    /// lesson is the first run of prose after the marker's colon. When the model
    /// writes a compound sentence that names a friction and then states a
    /// takeaway, the takeaway is the half worth keeping — it is the actionable
    /// sentence.
    private static func lessonCandidates(_ report: String) -> [String] {
        var candidates: [String] = []

        for rawLine in report.components(separatedBy: .newlines) {
            let line = Self.stripMarkdown(rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            for marker in lessonMarkers
            where line.range(of: marker, options: [.caseInsensitive]) != nil {
                guard let colon = firstColon(of: line) else { continue }

                // `line[colon...]` includes the colon itself; step past it.
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { break }

                if let takeaway = sentences(value).first(where: { sentence in
                    imperativeStarters.contains { sentence.hasPrefix($0) }
                }) {
                    candidates.append(takeaway)
                } else {
                    candidates.append(value)
                }
                break
            }
        }
        return candidates
    }

    /// Standalone imperative sentences from anywhere in the report.
    private static func imperativeCandidates(_ report: String) -> [String] {
        // Strip fenced code blocks first: a code comment that reads "never do X"
        // is not a lesson.
        let prose = removeCodeFences(report)

        return sentences(prose).filter { sentence in
            imperativeStarters.contains { sentence.hasPrefix($0) }
        }
    }

    // MARK: - Cleanup

    /// Trims a raw candidate down to something quotable.
    private static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Cut trailing markdown list markers and emphasis.
        while let last = value.last, "*-_".contains(last) {
            value = String(value.dropLast())
        }
        while let first = value.first, "*-_`".contains(first) {
            value = String(value.dropFirst())
        }

        // A lesson may run on into a bullet; stop at the list marker.
        if let bulletRange = value.range(of: "  * ") {
            value = String(value[..<bulletRange.lowerBound])
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        // One sentence only. Keeping the first sentence avoids harvesting a
        // whole paragraph that merely happens to start well.
        if value.contains(". ") {
            value = firstSentence(of: value)
        }

        return value
    }

    private static func isAcceptable(_ text: String) -> Bool {
        guard text.count >= minimumLength, text.count <= maximumLength else { return false }

        // Must contain prose, not just symbols or punctuation.
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters > text.count / 3 else { return false }

        // A sentence needs a verb-ish shape; reject anything that is one symbol
        // dump or a path.
        guard text.contains(" ") else { return false }
        if text.hasPrefix("/") || text.hasPrefix("~") { return false }

        // Reject anything that still carries code or link syntax, which means
        // the extraction was not clean.
        if text.contains("`") || text.contains("](") || text.contains("```") { return false }

        // Reject questions — they are not rules.
        if text.hasSuffix("?") { return false }

        return true
    }

    // MARK: - Text helpers

    private static func firstColon(of line: String) -> String.Index? {
        line.firstIndex(of: ":")
    }

    private static func removeCodeFences(_ text: String) -> String {
        text
            .components(separatedBy: "```")
            .enumerated()
            .filter { $0.offset % 2 == 0 }
            .map { $0.element }
            .joined(separator: "\n")
    }

    /// Splits prose into sentences, keeping each sentence's terminator attached.
    ///
    /// Splitting on `.`/`!`/`?` alone would strip the punctuation, and a rule of
    /// thumb that reads "...where a unit test passes quietly" without a full stop
    /// looks wrong in the profile and reads wrong when injected into a prompt.
    private static func sentences(_ text: String) -> [String] {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        var result: [String] = []
        var current = ""

        for character in flattened {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    /// The first sentence of a candidate, re-terminated.
    static func firstSentence(of text: String) -> String {
        guard let termination = text.rangeOfCharacter(
            from: CharacterSet(charactersIn: ".!?"),
            options: [],
            range: text.startIndex..<text.index(text.startIndex, offsetBy: min(text.count, 400))
        ) else {
            return text
        }
        return String(text[..<termination.upperBound])
    }
    /// Removes Markdown emphasis, code ticks, bullets and headers from a line
    /// so harvested rules read as plain sentences in the JSON profile.
    ///
    /// Lives here rather than on `ReportArchiver` because it is a pure text
    /// function, and this type must stay `nonisolated` so the harvester can run
    /// anywhere without a main-actor hop.
    static func stripMarkdown(_ text: String) -> String {
        var result = text
        for token in ["**", "__", "`", "*", "#", ">"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        result = result.replacingOccurrences(of: "- [ ] ", with: "")
        result = result.replacingOccurrences(of: "- [x] ", with: "")
        while result.hasPrefix("- ") { result.removeFirst(2) }
        while result.hasPrefix(" ") { result.removeFirst() }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
