import Foundation
import os

/// Laya System 1 Decision Engine bridge.
///
/// Runs a local Python process (laya-mlx on Apple Silicon) to make fast typed
/// decisions about captured OCR text before it reaches the cloud LLM. Falls
/// back to deterministic rules when Python/laya is unavailable.
@MainActor
final class DecisionEngineService: ObservableObject {

    private let logger = Logger(subsystem: AppInfo.identifier, category: "decision-engine")

    @Published private(set) var totalTokensSaved: Int = 0
    @Published private(set) var totalFramesProcessed: Int = 0
    @Published private(set) var totalFramesDropped: Int = 0
    @Published private(set) var totalFramesPurged: Int = 0
    @Published private(set) var lastLatencyMs: Double = 0
    @Published private(set) var isAvailable: Bool = false

    private let runnerScriptPath: String
    private let pythonPath: String

    init() {
        // Find the runner script
        let bundlePath = Bundle.main.resourceURL?.appendingPathComponent("laya_decision_runner.py").path
        let repoPath = FileManager.default.currentDirectoryPath + "/Scripts/laya_decision_runner.py"
        if let bundlePath, FileManager.default.fileExists(atPath: bundlePath) {
            runnerScriptPath = bundlePath
        } else if FileManager.default.fileExists(atPath: repoPath) {
            runnerScriptPath = repoPath
        } else {
            // Try to find it relative to the executable
            let execDir = (Bundle.main.executableURL?.deletingLastPathComponent().path ?? "") + "/../Scripts/laya_decision_runner.py"
            runnerScriptPath = execDir
        }

        // Find python3
        let pythonCandidates = [
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3"
        ]
        pythonPath = pythonCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"

        // Check if laya is available
        Task {
            await checkAvailability()
        }
    }

    private func checkAvailability() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-c", "import laya_mlx; print('OK')"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            isAvailable = (process.terminationStatus == 0 && output == "OK")
            if isAvailable {
                logger.notice("Laya Decision Engine available — \(self.pythonPath, privacy: .public)")
            } else {
                logger.notice("Laya not available — using deterministic fallback")
            }
        } catch {
            isAvailable = false
            logger.notice("Laya check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The 4 typed questions for Laya, tailored to DayPilot's use case.
    static let layaQuestions: [String: Any] = [
        "is_meaningful_work": [
            "type": "noul",
            "instructions": "Does this screen show meaningful work activity (coding, writing, research, planning)? Or is it idle, social scrolling, system UI, or empty chatter?"
        ],
        "is_discarded_insight": [
            "type": "noul",
            "instructions": "Does this contain a transient AI chat response, unsaved code idea, research note, or scratchpad content that should be rescued before the window closes?"
        ],
        "data_sensitivity": [
            "type": "score",
            "instructions": "How sensitive is the data visible on screen?",
            "criteria": [
                "none: no sensitive data visible",
                "common: normal work data, no PII",
                "sensitive: personal or confidential information",
                "secrets: API keys, passwords, .env files, tokens, credentials"
            ]
        ],
        "work_category": [
            "type": "choice",
            "instructions": "What category of work is this?",
            "criteria": [
                "deep_coding: writing, debugging, or reviewing code",
                "ai_research: AI research, experimentation, or prompt engineering",
                "docs_planning: documentation, planning, or design",
                "routine_admin: routine administrative tasks, email, browsing"
            ]
        ]
    ]

    /// Decision result from Laya.
    struct Decision: Sendable {
        let isMeaningfulWork: Bool
        let meaningfulProbability: Double
        let isDiscardedInsight: Bool
        let insightProbability: Double
        let dataSensitivity: String // none, common, sensitive, secrets
        let sensitivityScore: Double
        let workCategory: String // deep_coding, ai_research, docs_planning, routine_admin
        let latencyMs: Double
        let tokensSavedEstimate: Int
        let model: String
    }

    /// Runs the Laya decision engine on a state string.
    func decide(state: String) async -> Decision? {
        guard FileManager.default.fileExists(atPath: runnerScriptPath) else {
            logger.warning("Runner script not found at \(self.runnerScriptPath, privacy: .public)")
            return nil
        }
        if false { print("DEBUG: runner path = \(runnerScriptPath), python = \(pythonPath)") }

        let input: [String: Any] = [
            "state": state,
            "questions": Self.layaQuestions
        ]

        guard let inputData = try? JSONSerialization.data(withJSONObject: input) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [runnerScriptPath]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            // Write input
            inputPipe.fileHandleForWriting.write(inputData)
            inputPipe.fileHandleForWriting.closeFile()

            // Wait for completion
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: outputData, encoding: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
                logger.warning("Failed to parse Laya output")
                return nil
            }

            if let error = json["error"] as? String {
                logger.warning("Laya error: \(error, privacy: .public)")
            }

            let meaningful = json["is_meaningful_work"] as? [String: Any]
            let insight = json["is_discarded_insight"] as? [String: Any]
            let sensitivity = json["data_sensitivity"] as? [String: Any]
            let category = json["work_category"] as? [String: Any]

            let decision = Decision(
                isMeaningfulWork: meaningful?["decision"] as? Bool ?? true,
                meaningfulProbability: meaningful?["probability"] as? Double ?? 0.5,
                isDiscardedInsight: insight?["decision"] as? Bool ?? false,
                insightProbability: insight?["probability"] as? Double ?? 0.0,
                dataSensitivity: sensitivity?["label"] as? String ?? "common",
                sensitivityScore: sensitivity?["score"] as? Double ?? 0.0,
                workCategory: category?["choice"] as? String ?? "routine_admin",
                latencyMs: json["latency_ms"] as? Double ?? 0,
                tokensSavedEstimate: json["tokens_saved_estimate"] as? Int ?? 0,
                model: json["model"] as? String ?? "unknown"
            )

            // Update counters
            totalFramesProcessed += 1
            totalTokensSaved += decision.tokensSavedEstimate
            if !decision.isMeaningfulWork {
                totalFramesDropped += 1
            }
            if decision.dataSensitivity == "secrets" {
                totalFramesPurged += 1
            }
            lastLatencyMs = decision.latencyMs

            return decision

        } catch {
            logger.error("Laya process failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
