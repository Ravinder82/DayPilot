import Foundation
import os
import Vision

/// What one OCR pass produced, including the diff that gets stored.
struct TextExtractionResult: Sendable {
    /// Every recognized line, deduplicated, in reading order.
    let lines: [String]
    /// Full recognized text of the frame.
    let fullText: String
    /// Only the lines that appeared or changed since the previous pass.
    let textDelta: String
    /// Lines that were on screen before and are gone now.
    let removedLines: [String]
    /// Lines discarded from the delta because they were already recorded.
    let discardedRedundantLines: Int
    /// How long Vision took, in seconds.
    let recognitionDuration: TimeInterval
}

/// Runs Apple's Vision text recognition on captured frames.
///
/// This is an `actor` on purpose: OCR is the single most expensive operation
/// DayPilot performs, and serialising it keeps Vision from ever running two
/// passes concurrently (which would contend for the Neural Engine). The actor
/// executor is a cooperative thread pool, never the main actor, so a long pass
/// cannot stall the UI.
actor VisionTextExtractor {

    private let logger = Logger(subsystem: AppInfo.identifier, category: "ocr")

    /// Lines from the previous recognition, held so each pass can diff instead
    /// of re-reporting the same text every 15 seconds.
    private var previousLines: [String] = []

    /// Above this many line pairs, the quadratic LCS is skipped in favour of a
    /// set difference so a pathological screen (a full-page terminal dump)
    /// cannot stall recognition.
    private static let maximumDiffCells = 400_000

    // MARK: - Configuration

    /// Builds the recognition request.
    ///
    /// `usesCPUOnly = false` is the important one: it lets Vision choose the
    /// Neural Engine on Apple Silicon, which is the only reason this app can
    /// sample a screen all day without becoming a battery sink. The CPU path
    /// would be several times slower and would show up in Activity Monitor.
    private func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()

        // `.accurate` is slower than `.fast` and the right trade here: these
        // samples happen four times a minute, not per frame, and a fuzzy read
        // of a prompt being drafted is a lost breadcrumb.
        request.recognitionLevel = .accurate

        // Language correction matters because most of what is on screen is
        // code, where an unrecognised identifier is worse than a misrecognised
        // word.
        request.usesLanguageCorrection = true

        // Revision 3 is the Neural Engine implementation, and it is what this
        // OS ships as the default. `usesCPUOnly` used to be how an engine was
        // forced, but it was deprecated in macOS 14 — revision 3 does not
        // honour it — so pinning the revision is the supported way to stay on
        // the ANE instead of the CPU.
        if #available(macOS 13.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }

        request.minimumTextHeight = 0.008
        return request
    }

    // MARK: - Recognition

    /// Recognizes text in a frame and diffs it against the previous one.
    ///
    /// - Parameter image: A CGImage from `ScreenCaptureEngine`. Orientation is
    ///   always `.up` because the frame is a capture of a display, never a
    ///   camera photo.
    func extractText(from image: CGImage) throws -> TextExtractionResult {
        let started = Date()

        let request = makeRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])

        do {
            try handler.perform([request])
        } catch {
            logger.error("Vision recognition failed: \(error.localizedDescription, privacy: .public)")
            throw VisionExtractionError.recognitionFailed(error.localizedDescription)
        }

        let duration = Date().timeIntervalSince(started)

        // `VNRecognizeTextRequest.results` is already typed as
        // `[VNRecognizedTextObservation]?`, so no downcast is needed.
        let recognized: [String] = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }

        let lines = Self.deduplicated(recognized)
        let diff = Self.diff(previousLines, lines)
        previousLines = lines

        if lines.isEmpty {
            // A screen with no readable text (a video, a game, a photo) is
            // recorded as such rather than as a failed read.
            previousLines = []
        }

        return TextExtractionResult(
            lines: lines,
            fullText: lines.joined(separator: "\n"),
            textDelta: diff.added.joined(separator: "\n"),
            removedLines: diff.removed,
            discardedRedundantLines: max(0, lines.count - diff.added.count),
            recognitionDuration: duration
        )
    }

    /// Forgets the previous frame's text.
    ///
    /// Called when a session stops so the next session's first frame is treated
    /// as entirely new content rather than diffed against yesterday's screen.
    func reset() {
        previousLines = []
    }

    /// The text currently held as the comparison baseline.
    var lastRecognizedText: String { previousLines.joined(separator: "\n") }

    // MARK: - Diff

    /// Line-level diff between two frames.
    ///
    /// Returns the added and removed lines. Lines unchanged between frames are
    /// simply absent from `added` — that is the "discriminate redundant text
    /// blocks" rule, applied per line rather than per block so a single changed
    /// sentence inside a static paragraph still diffs.
    static func diff(
        _ previous: [String],
        _ current: [String]
    ) -> (added: [String], removed: [String]) {
        if previous.isEmpty { return (current, []) }
        if current.isEmpty { return ([], previous) }

        guard previous.count * current.count <= maximumDiffCells else {
            // Bounded fallback for pathologically large frames.
            let previousSet = Set(previous)
            let currentSet = Set(current)
            return (
                current.filter { !previousSet.contains($0) },
                previous.filter { !currentSet.contains($0) }
            )
        }

        let rowCount = previous.count
        let columnCount = current.count

        // lcsTable[i][j] holds the length of the longest common subsequence of
        // previous[i...] and current[j...].
        var lcsTable = [[Int]](
            repeating: [Int](repeating: 0, count: columnCount + 1),
            count: rowCount + 1
        )

        for i in stride(from: rowCount - 1, through: 0, by: -1) {
            for j in stride(from: columnCount - 1, through: 0, by: -1) {
                if previous[i] == current[j] {
                    lcsTable[i][j] = lcsTable[i + 1][j + 1] + 1
                } else {
                    lcsTable[i][j] = max(lcsTable[i + 1][j], lcsTable[i][j + 1])
                }
            }
        }

        var added: [String] = []
        var removed: [String] = []
        var i = 0
        var j = 0

        while i < rowCount, j < columnCount {
            if previous[i] == current[j] {
                i += 1
                j += 1
            } else if lcsTable[i + 1][j] >= lcsTable[i][j + 1] {
                removed.append(previous[i])
                i += 1
            } else {
                added.append(current[j])
                j += 1
            }
        }
        while i < rowCount {
            removed.append(previous[i])
            i += 1
        }
        while j < columnCount {
            added.append(current[j])
            j += 1
        }

        return (added, removed)
    }

    /// Drops duplicate lines while preserving reading order.
    ///
    /// Screen text repeats constantly — tab bars, toolbars, dock labels — and
    /// every repeat that survived would be re-stored as a "new" line.
    static func deduplicated(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                unique.append(trimmed)
            }
        }
        return unique
    }
}

enum VisionExtractionError: LocalizedError {
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .recognitionFailed(let message):
            "Text recognition failed: \(message)"
        }
    }
}
