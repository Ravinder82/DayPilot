import SwiftUI
import ScreenCaptureKit

/// The tabs of the Settings window, in the order people reach for them.
enum SettingsTab: Hashable, CaseIterable {
    case providers
    case pomodoro
}

/// The Settings window (⌘,).
///
/// Built to macOS Settings conventions: grouped forms, one primary action per
/// section, destructive actions behind a confirmation, and every value that
/// matters shown rather than hidden. Changes apply as they are made, so there is
/// no pending state that closing the window could lose.
struct SettingsView: View {

    @ObservedObject private var model: AppModel
    @ObservedObject private var settings: AppSettings

    @State private var selectedTab: SettingsTab
    @State private var modelFilter: ModelFilter = .all
    @State private var apiKeyDraft = ""
    @State private var apiKeyIsRevealed = false
    @State private var hasStoredKey = false
    @State private var verification: Verification?
    @State private var isTesting = false
    @State private var customSheet: CustomProviderMode?
    @State private var showingRemoveProvider = false
    @State private var showingRemoveKeys = false

    init(model: AppModel, initialTab: SettingsTab = .providers) {
        _model = ObservedObject(wrappedValue: model)
        _settings = ObservedObject(wrappedValue: model.settings)
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            providersTab
                .tabItem { Label("Providers", systemImage: "cpu") }
                .tag(SettingsTab.providers)

            pomodoroTab
                .tabItem { Label("Pomodoro", systemImage: "timer") }
                .tag(SettingsTab.pomodoro)

        }
        .frame(width: 620, height: 680)
    }

    // MARK: - Providers

    private var providersTab: some View {
        Form {
            providerSection
            modelSection
            credentialsSection
            connectionSection
            permissionSection
            developerSection
            dangerSection
        }
        .formStyle(.grouped)
        .onAppear(perform: loadSelection)
        .sheet(item: $customSheet) { mode in
            CustomProviderSheet(model: model, mode: mode) { _ in
                loadSelection()
            }
        }
        .confirmationDialog(
            "Remove \(activeProvider.label)?",
            isPresented: $showingRemoveProvider,
            titleVisibility: .visible
        ) {
            Button("Remove Provider", role: .destructive) { removeActiveCustomProvider() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its key is deleted from the Keychain. Existing debriefs are not affected.")
        }
        .confirmationDialog(
            "Remove every stored API key?",
            isPresented: $showingRemoveKeys,
            titleVisibility: .visible
        ) {
            Button("Remove All Keys", role: .destructive) { removeAllKeys() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will need to enter each key again to use its provider.")
        }
    }

    private var providerSection: some View {
        Section {
            Picker("Provider", selection: providerBinding) {
                ForEach(model.allProviders, id: \.id) { provider in
                    Text(provider.label).tag(provider.id)
                }
            }

            HStack(spacing: 8) {
                Button("Add Custom Provider…") {
                    customSheet = .add
                }
                Spacer()
                if let profile = activeCustomProfile {
                    Button("Edit…") {
                        customSheet = .edit(profile)
                    }
                    Button("Remove…", role: .destructive) {
                        showingRemoveProvider = true
                    }
                }
            }
        } header: {
            Text("Provider")
        } footer: {
            Text("Any service with an OpenAI-compatible API works. Add its base URL, your key and a model ID.")
        }
    }

    private var modelSection: some View {
        Section {
            Picker("Show", selection: $modelFilter) {
                ForEach(ModelFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            List(selection: modelSelection) {
                ForEach(pickerOptions) { option in
                    ModelRowView(option: option)
                        .tag(option.id as String?)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 180, maxHeight: 350)

            TextField(
                "Model ID",
                text: modelIDBinding,
                prompt: Text("For example gpt-4o-mini or llama-3.3-70b-versatile")
            )
            .font(.body.monospaced())

            HStack(spacing: 10) {
                Button {
                    Task { await model.loadModels(for: activeProvider, force: true) }
                } label: {
                    Label("Refresh List", systemImage: "arrow.clockwise")
                }
                .disabled(model.areModelsLoading(for: activeProvider.id))

                if model.areModelsLoading(for: activeProvider.id) {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Text(priceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Free and paid models are labelled where the provider publishes prices. Models without a published price appear under All.")
        }
    }

    private var credentialsSection: some View {
        Section {
            HStack(spacing: 10) {
                if apiKeyIsRevealed {
                    TextField("API key", text: $apiKeyDraft)
                        .font(.body.monospaced())
                } else {
                    SecureField("API key", text: $apiKeyDraft)
                }

                Button(apiKeyIsRevealed ? "Hide" : "Show") {
                    apiKeyIsRevealed.toggle()
                }
                .help(apiKeyIsRevealed ? "Hide the key" : "Show the key while you type")
            }

            HStack(spacing: 8) {
                Button(hasStoredKey ? "Update in Keychain" : "Save to Keychain") {
                    saveKey()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedDraft.isEmpty)

                Button("Test Connection") {
                    Task { await testConnection() }
                }
                .disabled(trimmedDraft.isEmpty || isTesting)

                if hasStoredKey {
                    Button("Remove Key", role: .destructive) {
                        removeKey()
                    }
                }

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let verification {
                verificationView(verification)
            }
        } header: {
            Text("API key")
        } footer: {
            Text("Keys are stored in the macOS Keychain. Test Connection checks the key exactly as typed, before you save it.")
        }
    }

    private var connectionSection: some View {
        Section {
            LabeledContent("Endpoint") {
                Text(activeProvider.baseURL)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            LabeledContent("Configured from") {
                Text(model.configurationSourceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Connection")
        }
    }

    private var permissionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Refresh Screen Recording Status") {
                        Task { await refreshPermissionStatus() }
                    }
                    .buttonStyle(.bordered)

                    Button("Grant Accessibility…") {
                        WindowManager.requestAccessibilityPermissionPrompt()
                    }
                    .buttonStyle(.bordered)
                }

                Text("Accessibility adds window titles to captures — without it DayPilot still records on-screen text. If Screen Recording was just granted, click Refresh. For debug rebuilds that invalidate TCC, run in Terminal:\n  tccutil reset ScreenCapture com.daypilot.app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("DayPilot never asks macOS for screen access by itself: the Play button only reads the silent preflight, and the live probe runs when you click Refresh. If a grant looks stuck, quit and reopen DayPilot.")
        }
    }

    private func refreshPermissionStatus() async {
        // Silent preflight first; the live probe only runs once the grant
        // exists, so this check can never raise a consent dialog of its own.
        let preflight = ScreenRecordingPermission.isGranted()
        print("Screen Recording preflight: \(preflight ? "GRANTED" : "NOT GRANTED")")
        guard preflight else {
            print("Enable DayPilot in System Settings > Privacy & Security > Screen Recording, then click again.")
            return
        }
        let live = await ScreenRecordingPermission.confirmWithLiveProbe()
        print("Live probe: \(live ? "OK" : "FAILED")")
    }

    private var dangerSection: some View {
        Section {
            Button("Remove All Stored Keys…", role: .destructive) {
                showingRemoveKeys = true
            }
        }
    }

    private var developerSection: some View {
        Section {
            Button("Run Stress Test Simulation") {
                Task {
                    await LaunchHarness.runStressTest()
                }
            }
            .help("Feeds 200 realistic mixed workday events through Laya + Synthesis + Zero-Trace purge")
        } header: {
            Text("Developer")
        } footer: {
            Text("Runs a stress test with 200 events: coding sessions, 5 transient AI chats, 3 secret leaks, 80 noise screens. Verifies Laya filtering, synthesis quality, and zero-trace purge.")
        }
    }

    // MARK: - Pomodoro

    private var pomodoroTab: some View {
        Form {
            Section {
                LabeledContent("Work duration") {
                    Text("\(Int(settings.pomodoroWorkDuration / 60)) minutes")
                        .foregroundStyle(.secondary)
                }
                Slider(value: workDurationBinding, in: 60...3600, step: 60) {
                    Text("Work duration")
                } minimumValueLabel: {
                    Text("1m")
                } maximumValueLabel: {
                    Text("60m")
                }

                LabeledContent("Short break") {
                    Text("\(Int(settings.pomodoroShortBreakDuration / 60)) minutes")
                        .foregroundStyle(.secondary)
                }
                Slider(value: shortBreakBinding, in: 30...1800, step: 30) {
                    Text("Short break")
                } minimumValueLabel: {
                    Text("30s")
                } maximumValueLabel: {
                    Text("30m")
                }

                LabeledContent("Long break") {
                    Text("\(Int(settings.pomodoroLongBreakDuration / 60)) minutes")
                        .foregroundStyle(.secondary)
                }
                Slider(value: longBreakBinding, in: 60...3600, step: 60) {
                    Text("Long break")
                } minimumValueLabel: {
                    Text("1m")
                } maximumValueLabel: {
                    Text("60m")
                }

                Stepper("Cycles before long break: \(settings.pomodoroCyclesBeforeLongBreak)",
                        value: cyclesBinding, in: 2...10)
            } header: {
                Text("Durations")
            } footer: {
                Text("Standard Pomodoro: 25 min work, 5 min short break, 15 min long break every 4 cycles.")
            }

            Section {
                Toggle("Play sound on phase change", isOn: soundBinding)
            } header: {
                Text("Behavior")
            } footer: {
                Text("One control drives both: Start begins the session and the focus timer, Pause holds both, and Stop ends both and writes the Day Brief. While a session records, work and break phases run one after another.")
            }

            Section {
                Button("Reset to Defaults") {
                    settings.pomodoroWorkDuration = 25 * 60
                    settings.pomodoroShortBreakDuration = 5 * 60
                    settings.pomodoroLongBreakDuration = 15 * 60
                    settings.pomodoroCyclesBeforeLongBreak = 4
                    settings.pomodoroSoundEnabled = true
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Verification feedback

    @ViewBuilder
    private func verificationView(_ state: Verification) -> some View {
        switch state {
        case .testing:
            Label("Testing \(activeProvider.label)…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .font(.callout)
        case .saved:
            Label("Saved to the Keychain.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .verified(let reply):
            Label("Connected. The model replied “\(reply)”.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case .info(let message):
            Label(message, systemImage: "info.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    // MARK: - Derived state

    private var activeProvider: SkillConfiguration.AIProvider {
        model.allProviders.first { $0.id == settings.preferredProviderID }
            ?? model.allProviders.first
            ?? SkillConfiguration.fallback.apiProviders.providers[0]
    }

    private var activeCustomProfile: CustomProviderProfile? {
        model.customProfiles.first { $0.id == activeProvider.id }
    }

    private var selectedModelID: String {
        settings.model(for: activeProvider)
    }

    private var availableModels: [AIModel] {
        model.availableModels(for: activeProvider)
    }

    private var visibleModels: [AIModel] {
        switch modelFilter {
        case .all: return availableModels
        case .free: return availableModels.filter { $0.price == .free }
        case .paid: return availableModels.filter { $0.price == .paid }
        }
    }

    /// The rows the list shows. A model typed by hand is kept at the top even
    /// when it is not in the catalogue, so the current choice is always visible.
    private var pickerOptions: [AIModel] {
        var options = visibleModels
        if !selectedModelID.isEmpty, !availableModels.contains(where: { $0.id == selectedModelID }) {
            options.insert(
                AIModel(id: selectedModelID, label: selectedModelID, price: .unknown, contextWindow: nil),
                at: 0
            )
        }
        return options
    }

    /// Says why the list is empty. A filter that matches nothing is a different
    /// problem from a catalogue that never loaded, and the advice differs.
    private var emptyModelListMessage: String {
        if availableModels.isEmpty {
            return "No models are loaded yet. Save a key and choose Refresh List, or type a model ID below."
        }
        return "No \(modelFilter.title.lowercased()) models are marked for this provider. Choose All to see every model it offers."
    }

    private var priceSummary: String {
        let all = availableModels
        guard !all.isEmpty else { return "" }
        let free = all.filter { $0.price == .free }.count
        let paid = all.filter { $0.price == .paid }.count
        return "\(free) free · \(paid) paid · \(all.count - free - paid) unpriced"
    }

    private var trimmedDraft: String {
        apiKeyDraft.trimmedForInput
    }

    // MARK: - Actions

    /// Reads the stored key and the catalogue for whichever provider is active.
    private func loadSelection() {
        let stored = KeychainManager.getKey(for: activeProvider.id) ?? ""
        apiKeyDraft = stored
        hasStoredKey = !stored.isEmpty
        apiKeyIsRevealed = false
        verification = nil
        Task { await model.loadModels(for: activeProvider) }
    }

    private func saveKey() {
        let key = trimmedDraft
        guard KeychainManager.saveKey(key, for: activeProvider.id) else {
            verification = .failed("The Keychain did not accept the key. Check that your login keychain is unlocked, then try again.")
            return
        }
        hasStoredKey = true
        verification = .saved
        AppConfiguration.shared.update(providerID: activeProvider.id, key: key)
        Task { await model.loadModels(for: activeProvider, force: true) }
    }

    private func removeKey() {
        KeychainManager.deleteKey(for: activeProvider.id)
        apiKeyDraft = ""
        hasStoredKey = false
        if AppConfiguration.shared.selectedProviderID == activeProvider.id {
            AppConfiguration.shared.clear()
        }
        verification = .info("The key was removed from the Keychain.")
    }

    /// Sends a five-token request with the key exactly as typed, so the result
    /// answers "is this key good?" before the user commits it to the Keychain.
    private func testConnection() async {
        let key = trimmedDraft
        guard !key.isEmpty else {
            verification = .failed("Paste a key first.")
            return
        }
        guard !selectedModelID.isEmpty else {
            verification = .failed("Choose a model, or type its ID, before testing the connection.")
            return
        }

        isTesting = true
        verification = .testing
        defer { isTesting = false }

        let client = APIClient.make(
            provider: activeProvider,
            apiKey: key,
            voiceScriptStartTag: model.skillConfiguration.audio.voiceScriptStartTag,
            voiceScriptEndTag: model.skillConfiguration.audio.voiceScriptEndTag,
            modelOverride: selectedModelID
        )

        do {
            let reply = try await client.testConnection()
            verification = .verified(String(reply.prefix(60)))
        } catch {
            verification = .failed(error.localizedDescription)
        }
    }

    private func removeActiveCustomProvider() {
        guard let profile = activeCustomProfile else { return }
        model.removeCustomProvider(profile)
        loadSelection()
    }

    private func removeAllKeys() {
        let removed = KeychainManager.deleteAll()
        apiKeyDraft = ""
        hasStoredKey = false
        AppConfiguration.shared.clear()
        verification = removed == 0
            ? .info("No keys were stored.")
            : .info("Removed \(removed) stored key\(removed == 1 ? "" : "s").")
    }

    // MARK: - Bindings

    private var providerBinding: Binding<String> {
        Binding(
            get: { activeProvider.id },
            set: { newValue in
                model.selectProvider(newValue)
                loadSelection()
            }
        )
    }

    /// The list's selection. Clearing it stores "no model", which the request
    /// path reports rather than sending an empty model name.
    private var modelSelection: Binding<String?> {
        Binding(
            get: { selectedModelID.isEmpty ? nil : selectedModelID },
            set: { newValue in
                settings.select(model: newValue ?? "", forProvider: activeProvider.id)
            }
        )
    }

    private var modelIDBinding: Binding<String> {
        Binding(
            get: { selectedModelID },
            set: { newValue in
                settings.select(model: newValue, forProvider: activeProvider.id)
            }
        )
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { settings.captureIntervalSeconds },
            set: { settings.captureIntervalSeconds = $0 }
        )
    }

    private var workDurationBinding: Binding<Double> {
        Binding(
            get: { settings.pomodoroWorkDuration },
            set: { settings.pomodoroWorkDuration = $0 }
        )
    }

    private var shortBreakBinding: Binding<Double> {
        Binding(
            get: { settings.pomodoroShortBreakDuration },
            set: { settings.pomodoroShortBreakDuration = $0 }
        )
    }

    private var longBreakBinding: Binding<Double> {
        Binding(
            get: { settings.pomodoroLongBreakDuration },
            set: { settings.pomodoroLongBreakDuration = $0 }
        )
    }

    private var cyclesBinding: Binding<Int> {
        Binding(
            get: { settings.pomodoroCyclesBeforeLongBreak },
            set: { settings.pomodoroCyclesBeforeLongBreak = $0 }
        )
    }

    private var soundBinding: Binding<Bool> {
        Binding(
            get: { settings.pomodoroSoundEnabled },
            set: { settings.pomodoroSoundEnabled = $0 }
        )
    }

    // MARK: - Types

    private enum Verification: Equatable {
        case testing
        case saved
        case verified(String)
        case failed(String)
        case info(String)
    }
}

/// Which models the list shows.
private enum ModelFilter: String, CaseIterable, Identifiable {
    case all
    case free
    case paid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .free: return "Free"
        case .paid: return "Paid"
        }
    }
}

/// One row of the model list: name, the exact id to send, context size and price.
private struct ModelRowView: View {

    let option: AIModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(option.label)
                    .lineLimit(1)
                Text(option.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            if let window = option.contextWindow {
                Text(contextText(window))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            priceBadge
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var priceBadge: some View {
        switch option.price {
        case .free:
            badge("Free", tint: .green)
        case .paid:
            badge("Paid", tint: .secondary)
        case .unknown:
            EmptyView()
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }

    private func contextText(_ tokens: Int) -> String {
        tokens >= 1_000_000 ? "\(tokens / 1_000_000)M context" : "\(tokens / 1_000)k context"
    }
}
