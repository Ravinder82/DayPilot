import SwiftUI
import ScreenCaptureKit
import AppKit

/// First-run onboarding flow. Shown when setup is incomplete.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var currentStep = 0
    @State private var permissionGranted = false
    @State private var isCheckingPermission = false
    @State private var permissionDiagnostic = ""
    @State private var selectedSensitiveApps: Set<String> = Set(DayPilotConfiguration.sensitiveBundleIdentifiers)
    @State private var customBundleID = ""
    @State private var apiKeyDraft = ""
    @State private var isTestingKey = false
    @State private var keyTestResult: String?
    @State private var selectedProviderID = "google_ai_studio"
    @State private var selectedModelPreset = "gemini-2.5-flash"
    @State private var customModelName = ""
    @State private var useCustomModel = false
    @State private var isVerified = false
    @State private var verifiedModelName = ""
    @State private var layaStatus: LayaStatus = .checking
    @State private var hasCompletedOnboarding = false

    enum LayaStatus {
        case checking
        case available
        case unavailable
    }

    private let totalSteps = 3

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    if step < totalSteps - 1 {
                        Rectangle()
                            .fill(step < currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(height: 2)
                            .frame(maxWidth: 40)
                    }
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Step content
            Group {
                switch currentStep {
                case 0: step1Permission
                case 1: step2PrivacyGuard
                case 2: step3KeychainLaya
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)

            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                if currentStep < totalSteps - 1 {
                    Button("Continue") {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
                } else {
                    Button("Open DayPilot") {
                        completeOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .frame(width: 600, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            autoCheckPermission()
            checkLayaStatus()
        }
    }

    private var canContinue: Bool {
        switch currentStep {
        case 0: return true  // Never hard-lock — user can always proceed
        case 1: return true
        case 2: return isVerified || !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return true
        }
    }

    // MARK: - Step 1: Permission Check

    private var step1Permission: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Zero-Trace Privacy")
                .font(.title2.weight(.semibold))

            Text("DayPilot captures your screen to generate a daily briefing. **Screenshots are never saved** — only the final Day Brief report is kept. All raw screen text is permanently erased after generation.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 450)

            VStack(spacing: 12) {
                if isCheckingPermission {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking Screen Recording permission…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if permissionGranted {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connected & Verified")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.green.opacity(0.1), in: Capsule())
                } else {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Screen Recording not granted")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        Text("Open System Settings → Privacy & Security → Screen Recording → Enable DayPilot")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 350)
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        .buttonStyle(.bordered)

                        // Diagnostic info
                        if !permissionDiagnostic.isEmpty {
                            Text(permissionDiagnostic)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 350)
                                .padding(.top, 4)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("Refresh Permission Status") {
                        checkPermission()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if !permissionGranted && !isCheckingPermission {
                        Button("Continue Anyway") {
                            withAnimation { currentStep += 1 }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    /// Runs when the step appears: silent preflight only — the live probe
    /// would raise macOS's consent dialog just for opening onboarding. The
    /// dialog belongs to the moment the user clicks Refresh, not to arrival.
    private func autoCheckPermission() {
        permissionGranted = ScreenRecordingPermission.isGranted()
        permissionDiagnostic = permissionGranted
            ? ""
            : "Not granted yet — open System Settings, enable DayPilot, then click Refresh Permission Status."
    }

    private func checkPermission() {
        isCheckingPermission = true
        permissionDiagnostic = ""
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                await MainActor.run {
                    permissionGranted = !content.displays.isEmpty
                    isCheckingPermission = false
                    if !permissionGranted {
                        permissionDiagnostic = "Bundle: \(Bundle.main.bundlePath)\nDisplays found: \(content.displays.count)"
                    }
                }
            } catch {
                await MainActor.run {
                    permissionGranted = false
                    isCheckingPermission = false
                    permissionDiagnostic = "Bundle: \(Bundle.main.bundlePath)\nError: \(error.localizedDescription)\nCode: \((error as NSError).code)"
                }
            }
        }
    }

    // MARK: - Step 2: Privacy Guard

    private var step2PrivacyGuard: some View {
        VStack(spacing: 20) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Privacy Guard Setup")
                .font(.title2.weight(.semibold))

            Text("DayPilot will never capture these sensitive apps. Pre-selected for your protection — toggle or add custom apps.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 450)

            VStack(spacing: 8) {
                ForEach(sensitiveAppList, id: \.bundleID) { app in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { selectedSensitiveApps.contains(app.bundleID) },
                            set: { isOn in
                                if isOn { selectedSensitiveApps.insert(app.bundleID) }
                                else { selectedSensitiveApps.remove(app.bundleID) }
                            }
                        )) {
                            HStack(spacing: 8) {
                                Image(systemName: app.icon)
                                    .frame(width: 20)
                                Text(app.name)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }

                Divider()

                HStack {
                    TextField("Custom bundle ID (e.g., com.example.app)", text: $customBundleID)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        if !customBundleID.trimmingCharacters(in: .whitespaces).isEmpty {
                            selectedSensitiveApps.insert(customBundleID.trimmingCharacters(in: .whitespaces))
                            customBundleID = ""
                        }
                    }
                    .disabled(customBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12)
            }
            .frame(maxWidth: 450)
        }
    }

    private struct SensitiveApp {
        let bundleID: String
        let name: String
        let icon: String
    }

    private let modelPresets: [String: [String]] = [
        "google_ai_studio": ["gemini-2.5-flash", "gemini-3-flash-preview", "gemini-2.5-pro"],
        "openrouter_free": ["meta-llama/llama-3.3-70b-instruct:free", "deepseek/deepseek-chat:free", "google/gemini-2.0-flash-exp:free"],
        "openai_compatible": []
    ]

    private var effectiveModelName: String {
        if useCustomModel {
            return customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return selectedModelPreset
    }

    private var sensitiveAppList: [SensitiveApp] {
        [
            SensitiveApp(bundleID: "com.1password.1password", name: "1Password", icon: "key.fill"),
            SensitiveApp(bundleID: "com.agilebits.onepassword7", name: "1Password 7", icon: "key.fill"),
            SensitiveApp(bundleID: "com.apple.keychainaccess", name: "Keychain Access", icon: "lock.fill"),
            SensitiveApp(bundleID: "com.apple.MobileSMS", name: "Messages", icon: "message.fill"),
            SensitiveApp(bundleID: "com.apple.mail", name: "Mail", icon: "envelope.fill"),
            SensitiveApp(bundleID: "com.apple.FaceTime", name: "FaceTime", icon: "video.fill"),
            SensitiveApp(bundleID: "com.apple.Safari", name: "Safari (Private/Banking)", icon: "globe"),
        ]
    }

    // MARK: - Step 3: Keychain & Laya

    private var step3KeychainLaya: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Secure Keychain & AI Model")
                .font(.title2.weight(.semibold))

            Text("Paste your OpenAI-compatible API key. It's stored exclusively in macOS Keychain — never in plaintext. Choose or type your model name.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 450)

            VStack(spacing: 12) {
                // Provider picker
                Picker("AI Provider", selection: $selectedProviderID) {
                    Text("Google Gemini").tag("google_ai_studio")
                    Text("OpenRouter").tag("openrouter_free")
                    Text("OpenAI-Compatible").tag("openai_compatible")
                }
                .pickerStyle(.segmented)
                .frame(width: 350)

                // Model name selector
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if modelPresets[selectedProviderID]?.isEmpty == false {
                        Picker("Preset", selection: $selectedModelPreset) {
                            ForEach(modelPresets[selectedProviderID] ?? [], id: \.self) { preset in
                                Text(preset).tag(preset)
                            }
                            Text("Custom…").tag("__custom__")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 350)
                        .onChange(of: selectedModelPreset) { _, newValue in
                            useCustomModel = (newValue == "__custom__")
                        }
                    }

                    if useCustomModel || (modelPresets[selectedProviderID]?.isEmpty == true) {
                        TextField("Custom Model Name (e.g., gemini-2.5-pro)", text: $customModelName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 350)
                    }
                }

                // API Key input
                SecureField("API Key", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 350)

                // Test Connection button
                HStack(spacing: 8) {
                    Button(isTestingKey ? "Testing…" : "Test Connection") {
                        testConnection()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTestingKey || apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty || effectiveModelName.isEmpty)

                    if isTestingKey {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                // Verification badge
                if isVerified {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Verified: Connected to \(verifiedModelName)")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.green.opacity(0.1), in: Capsule())
                }

                if let result = keyTestResult, !isVerified {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("✓") ? .green : .red)
                }

                Divider()

                // Laya status
                HStack(spacing: 8) {
                    switch layaStatus {
                    case .checking:
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking Laya Decision Engine…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .available:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Laya Decision 1 Engine: Available (~33ms/pass)")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.green)
                    case .unavailable:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Laya: Using deterministic fallback (install: pip install laya-mlx)")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func testConnection() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            keyTestResult = "✗ Enter an API key"
            return
        }
        let modelName = effectiveModelName
        guard !modelName.isEmpty else {
            keyTestResult = "✗ Enter a model name"
            return
        }

        isTestingKey = true
        keyTestResult = nil

        Task {
            // Build provider config
            let provider: SkillConfiguration.AIProvider
            switch selectedProviderID {
            case "google_ai_studio":
                provider = SkillConfiguration.AIProvider(
                    id: "google_ai_studio", label: "Google Gemini",
                    baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
                    apiKeyEnvironmentVariable: "GEMINI_API_KEY", model: modelName,
                    temperature: 0.3, maxContextWindow: 1_048_576, costPerMillionInput: 0, isFreeTier: true
                )
            case "openrouter_free":
                provider = SkillConfiguration.AIProvider(
                    id: "openrouter_free", label: "OpenRouter",
                    baseURL: "https://openrouter.ai/api/v1",
                    apiKeyEnvironmentVariable: "OPENROUTER_API_KEY", model: modelName,
                    temperature: 0.3, maxContextWindow: 128_000, costPerMillionInput: 0, isFreeTier: true
                )
            default:
                provider = SkillConfiguration.AIProvider(
                    id: "openai_compatible", label: "OpenAI-Compatible",
                    baseURL: "https://api.openai.com/v1",
                    apiKeyEnvironmentVariable: "OPENAI_API_KEY", model: modelName,
                    temperature: 0.3, maxContextWindow: 128_000, costPerMillionInput: 0, isFreeTier: false
                )
            }

            let client = APIClient.make(
                provider: provider,
                apiKey: key,
                voiceScriptStartTag: "[VOICE_SCRIPT]",
                voiceScriptEndTag: "[/VOICE_SCRIPT]",
                modelOverride: modelName
            )

            do {
                _ = try await client.testConnection()
                await MainActor.run {
                    isVerified = true
                    verifiedModelName = modelName
                    keyTestResult = "✓ Verified: Connected to \(modelName)"

                    // Save to Keychain
                    KeychainManager.saveKey(key, for: selectedProviderID)
                    AppConfiguration.shared.update(providerID: selectedProviderID, key: key)
                    model.selectProvider(selectedProviderID)
                    model.settings.select(model: modelName, forProvider: selectedProviderID)
                }
            } catch {
                await MainActor.run {
                    isVerified = false
                    keyTestResult = "✗ \(error.localizedDescription)"
                }
            }
            await MainActor.run {
                isTestingKey = false
            }
        }
    }

    private func saveKey() {
        // Delegate to testConnection which handles saving
        testConnection()
    }

    private func checkLayaStatus() {
        layaStatus = .checking
        Task {
            let available = model.layaAvailable
            await MainActor.run {
                layaStatus = available ? .available : .unavailable
            }
        }
    }

    private func completeOnboarding() {
        // Save selected sensitive apps to configuration
        let defaults = UserDefaults.standard
        let bundleIDs = Array(selectedSensitiveApps)
        defaults.set(bundleIDs, forKey: "onboarding.sensitiveBundleIDs")
        defaults.set(true, forKey: "onboarding.completed")

        // Persist model selection
        if isVerified {
            model.settings.select(model: effectiveModelName, forProvider: selectedProviderID)
        }

        // Add custom bundle IDs to config
        // (These are stored in UserDefaults for the shield to read)

        hasCompletedOnboarding = true
        // Notify parent to close onboarding and show main window
        dismiss()
    }
}

/// Check if onboarding has been completed.
extension OnboardingView {
    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: "onboarding.completed")
    }
}