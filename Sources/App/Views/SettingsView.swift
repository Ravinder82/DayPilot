import SwiftUI
import ScreenCaptureKit

/// Settings, as a tab of the main window (⌘,).
///
/// Built to macOS Settings conventions: grouped forms, one primary action per
/// section, destructive actions behind a confirmation, and every value that
/// matters shown rather than hidden. Changes apply as they are made, so there is
/// no pending state that a switch away could lose.
///
/// It used to be a window of its own, which put it one app away from the work it
/// configures. As a tab it fills whatever room the main window gives it, rather
/// than the fixed 620×680 it was sized to when it had the screen to itself.
struct SettingsView: View {

    @ObservedObject private var model: AppModel
    @ObservedObject private var settings: AppSettings

    @State private var modelFilter: ModelFilter = .all
    @State private var apiKeyDraft = ""
    @State private var apiKeyIsRevealed = false
    @State private var hasStoredKey = false
    @State private var verification: Verification?
    @State private var isTesting = false
    @State private var customSheet: CustomProviderMode?
    @State private var showingRemoveProvider = false
    @State private var showingRemoveKeys = false

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
        _settings = ObservedObject(wrappedValue: model.settings)
    }

    var body: some View {
        providersTab
            .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
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

            modelList

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

    /// The model catalogue, in its own scroller.
    ///
    /// A `List` nested in a grouped `Form` is flattened into the form's own
    /// scroll view on macOS, so it clips instead of scrolling — with a full
    /// catalogue the rows simply ran off the bottom of their frame. A
    /// `ScrollView` keeps its own scroller however deep it is nested, so every
    /// model is reachable without scrolling the whole pane first.
    private var modelList: some View {
        ScrollView {
            if pickerOptions.isEmpty {
                Text(emptyModelListMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(pickerOptions.enumerated()), id: \.element.id) { index, option in
                        modelRow(option, index: index)
                    }
                }
            }
        }
        .frame(minHeight: 180, maxHeight: 350)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .accessibilityLabel("Available models")
        .accessibilityHint("Scrolls. Choose a row to select that model.")
    }

    private func modelRow(_ option: AIModel, index: Int) -> some View {
        let isSelected = option.id == selectedModelID
        return ModelRowView(option: option)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.18)
                    : (index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
            )
            .overlay(alignment: .bottom) {
                if index < pickerOptions.count - 1 {
                    Divider().padding(.leading, 10)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { modelIDBinding.wrappedValue = option.id }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { modelIDBinding.wrappedValue = option.id }
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
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text(option.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
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
