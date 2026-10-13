// AVFoundation's speech-synthesis delegate is not annotated for Swift
// concurrency, so the SDK's own requirement is treated as nonisolated. Marking
// the import `@preconcurrency` is the documented way to tell Swift "this
// framework predates strict isolation", which lets a `@MainActor` class conform
// without silencing anything about our own code.
@preconcurrency import AVFoundation
import Combine
import os

/// Speaks the debrief with the system speech synthesizer.
///
/// `AVSpeechSynthesizer` is not thread-safe, so this type is `@MainActor`: every
/// entry point is serialized on the main actor, which also makes the published
/// state safe for SwiftUI and for the status bar to observe.
///
/// This is deliberately the on-device synthesiser and not a cloud voice — it
/// costs nothing, adds no network dependency, has no latency to establish a
/// connection, and keeps the day's content on the machine.
@MainActor
// Conformance is declared in the `@MainActor` extension below, not here: the
// class-level conformance is what Swift flags as crossing into main-actor code.
final class VoicePlaybackEngine: NSObject, ObservableObject {

    private let logger = Logger(subsystem: AppInfo.identifier, category: "voice")

    // MARK: - Observable state

    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false

    /// The voice chosen for playback, once a session has started speaking.
    @Published private(set) var activeVoiceIdentifier: String?

    /// Human-readable reason speech is unavailable, when it is. Surfaced so the
    /// menu bar can explain a silent debrief instead of looking broken.
    @Published private(set) var unavailabilityReason: String?

    private let synthesizer = AVSpeechSynthesizer()

    private let configuration: SkillConfiguration.Audio

    /// Mutable so the user can switch voice at runtime without rebuilding the
    /// engine, which also keeps `speak` allocations off the hot path.
    private var selectedVoice: AVSpeechSynthesisVoice?

    /// Holds the auto-stop timer for `speak(text:autoStopAfter:)`.
    private var autoStopTask: Task<Void, Never>?

    // MARK: - Init

    init(configuration: SkillConfiguration.Audio = SkillConfiguration.fallback.audio) {
        self.configuration = configuration
        // Resolve the voice before `super.init` so nothing later captures `self`
        // implicitly.
        let voice = Self.selectVoice(
            preferredIdentifiers: configuration.preferredVoiceIdentifiers
        )
        selectedVoice = voice
        super.init()

        synthesizer.delegate = self

        if let voice {
            activeVoiceIdentifier = voice.identifier
            if voice.quality != .enhanced {
                unavailabilityReason = "No enhanced voice available; falling back to \(voice.name)."
            }
        } else {
            unavailabilityReason = "No English voice found on this system; the spoken debrief is disabled."
        }

        logger.notice("Voice engine ready — \(voice?.identifier ?? "none", privacy: .public)")
    }

    // MARK: - Voice selection

    /// Picks the best available voice for English.
    ///
    /// Order of preference: the configured premium voices, then any enhanced
    /// English voice, then any English voice, then the system default. Enhanced
    /// voices are noticeably better for a 60-second briefing, but they can be
    /// uninstalled, so every step has a fallback.
    static func selectVoice(
        preferredIdentifiers: [String],
        language: String = "en-US"
    ) -> AVSpeechSynthesisVoice? {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        guard !installed.isEmpty else { return nil }

        for identifier in preferredIdentifiers {
            if let match = AVSpeechSynthesisVoice(identifier: identifier),
               installed.contains(where: { $0.identifier == match.identifier }) {
                return match
            }
        }

        if let enhanced = installed.first(where: {
            $0.language == language && $0.quality == .enhanced
        }) {
            return enhanced
        }

        if let languageMatch = installed.first(where: {
            $0.language == language
        }) {
            return languageMatch
        }

        return installed.first(where: { $0.language.hasPrefix("en") }) ?? installed.first
    }

    /// The voice currently in use, or `nil` for the system default.
    var activeVoice: AVSpeechSynthesisVoice? { selectedVoice }

    /// Switches the voice at runtime.
    ///
    /// Takes effect on the next utterance — switching mid-sentence would be
    /// audible. An empty identifier means "let DayPilot choose".
    func overrideVoiceIdentifier(_ identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        guard trimmed != selectedVoice?.identifier ?? "" else { return }

        if trimmed.isEmpty {
            let auto = Self.selectVoice(
                preferredIdentifiers: configuration.preferredVoiceIdentifiers
            )
            selectedVoice = auto
        } else if let match = Self.selectVoice(
            preferredIdentifiers: [trimmed],
            language: "en"
        ), AVSpeechSynthesisVoice.speechVoices()
            .contains(where: { $0.identifier == match.identifier }) {
            selectedVoice = match
        } else {
            logger.error("Requested voice \(trimmed, privacy: .public) is not installed; keeping the current one")
            return
        }

        let switched = selectedVoice?.identifier ?? "system default"
        activeVoiceIdentifier = selectedVoice?.identifier
        logger.notice("Voice switched to \(switched, privacy: .public)")
    }

    /// Every installed voice, sorted by language then quality, for the picker.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { lhs, rhs in
            if lhs.language != rhs.language { return lhs.language < rhs.language }
            if lhs.quality != rhs.quality { return lhs.quality == .enhanced }
            return lhs.name < rhs.name
        }
    }

    /// Speaks a short sample with the installed-voice default, for "Preview Voice".
    func previewVoice() {
        let phrase = "DayPilot is ready. This is how I will read your debrief."
        speak(text: phrase, autoStopAfter: 6)
    }

    // MARK: - Controls

    /// Speaks the text, optionally stopping after a bounded time.
    ///
    /// - Parameter autoStopAfter: If set, playback stops after this many
    ///   seconds. Used by the integration test to verify audio routing without
    ///   sitting through a full debrief.
    func speak(text: String, autoStopAfter: TimeInterval? = nil) {
        autoStopTask?.cancel()
        autoStopTask = nil

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logger.info("Nothing to speak — the voice script was empty")
            return
        }
        guard selectedVoice != nil else {
            let reason = unavailabilityReason ?? "no voice"
            logger.error("Cannot speak: \(reason, privacy: .public)")
            return
        }

        // Long strings are chunked into utterances: AVSpeechSynthesizer has an
        // internal limit, and one huge utterance fails without an error. Queueing
        // chunks also keeps `stop()` and `pause()` responsive mid-brief.
        let chunks = Self.chunk(trimmed, maxLength: 900)
        for (index, chunk) in chunks.enumerated() {
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.voice = selectedVoice
            // The config's 0.52 is deliberately slow: this is a dense briefing,
            // not a notification, and the listener is usually not reading.
            utterance.rate = configuration.rate
            utterance.pitchMultiplier = configuration.pitchMultiplier
            utterance.preUtteranceDelay = index == 0 ? 0 : 0.12
            utterance.postUtteranceDelay = index == chunks.count - 1 ? 0 : 0.08
            synthesizer.speak(utterance)
        }

        logger.notice("Speaking \(chunks.count) utterance(s), \(trimmed.count) characters")

        if let autoStopAfter, autoStopAfter > 0 {
            autoStopTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(autoStopAfter * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.stop()
                self?.logger.notice("Auto-stopped playback after \(autoStopAfter)s")
            }
        }
    }

    /// Pauses mid-utterance at the word boundary.
    func pause() {
        guard synthesizer.isSpeaking, !isPaused else { return }
        synthesizer.pauseSpeaking(at: .word)
        isPaused = true
        logger.info("Playback paused")
    }

    /// Resumes a paused utterance.
    func resume() {
        guard isPaused else { return }
        synthesizer.continueSpeaking()
        isPaused = false
        logger.info("Playback resumed")
    }

    /// Stops everything immediately.
    func stop() {
        autoStopTask?.cancel()
        autoStopTask = nil

        guard synthesizer.isSpeaking else {
            isSpeaking = false
            isPaused = false
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
        logger.info("Playback stopped")
    }

    /// Splits text into speakable chunks on sentence boundaries.
    ///
    /// Never splits a sentence across utterances, because a hard break mid
    /// sentence is audible.
    static func chunk(_ text: String, maxLength: Int) -> [String] {
        var chunks: [String] = []
        var current = ""

        // Split on sentence terminators, keeping the terminator attached so the
        // pause lands in the right place.
        let sentences = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for sentence in sentences {
            var candidate = current.isEmpty ? sentence : current + ". " + sentence
            if candidate.count > maxLength, !current.isEmpty {
                chunks.append(current + ".")
                current = sentence
                candidate = sentence
            }
            if candidate.count > maxLength {
                // A single sentence longer than the budget still has to be
                // spoken; split it at the last comma, or hard-split.
                let words = candidate.split(separator: " ")
                var buffer = ""
                for word in words {
                    if (buffer.count + word.count + 1) > maxLength, !buffer.isEmpty {
                        chunks.append(buffer)
                        buffer = String(word)
                    } else {
                        buffer = buffer.isEmpty ? String(word) : buffer + " " + word
                    }
                }
                current = buffer
            } else {
                current = candidate
            }
        }

        if !current.isEmpty { chunks.append(current + ".") }
        return chunks
    }
}

// AVFoundation delivers these callbacks on an internal queue, so the protocol's
// requirements are nonisolated. `@preconcurrency` on the conformance is the
// documented interop for a `@MainActor` type conforming to a protocol that
// predates strict isolation; the handlers themselves stay main-actor.
@MainActor
extension VoicePlaybackEngine: @preconcurrency AVSpeechSynthesizerDelegate {

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        isSpeaking = true
        isPaused = false
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        // `stopSpeaking` also lands here, so only clear the flags when the
        // queue is genuinely drained.
        guard !synthesizer.isSpeaking else { return }
        isSpeaking = false
        isPaused = false
        autoStopTask?.cancel()
        autoStopTask = nil
        logger.info("Playback finished")
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didPause utterance: AVSpeechUtterance
    ) {
        isPaused = true
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didContinue utterance: AVSpeechUtterance
    ) {
        isPaused = false
        isSpeaking = true
    }
}
