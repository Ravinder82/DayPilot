import SwiftUI

/// Whether the custom-provider sheet is adding a provider or editing one.
enum CustomProviderMode: Identifiable {
    case add
    case edit(CustomProviderProfile)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let profile): return "edit-\(profile.id)"
        }
    }
}

extension String {
    /// The string with surrounding whitespace and newlines removed, as pasted
    /// keys and endpoints usually carry both.
    var trimmedForInput: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Adds or edits an OpenAI-compatible provider: a name, a base URL, a key and,
/// optionally, the model to start with. The model list is loaded afterwards in
/// Settings, so the sheet never waits on the network.
struct CustomProviderSheet: View {

    @ObservedObject private var model: AppModel
    private let mode: CustomProviderMode
    private let onSaved: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var baseURL: String
    @State private var apiKey: String
    @State private var modelID: String
    @State private var errorMessage: String?

    init(model: AppModel, mode: CustomProviderMode, onSaved: @escaping (String) -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.mode = mode
        self.onSaved = onSaved

        switch mode {
        case .add:
            _name = State(initialValue: "")
            _baseURL = State(initialValue: "https://")
            _apiKey = State(initialValue: "")
            _modelID = State(initialValue: "")
        case .edit(let profile):
            _name = State(initialValue: profile.label)
            _baseURL = State(initialValue: profile.baseURL)
            _apiKey = State(initialValue: KeychainManager.getKey(for: profile.id) ?? "")
            _modelID = State(initialValue: model.settings.model(for: profile.provider))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text("Any OpenAI-compatible service works. Give it a name, its base URL and your key. You choose the model after it is added.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            Form {
                TextField("Name", text: $name, prompt: Text("For example Together AI"))

                TextField("Base URL", text: $baseURL, prompt: Text("https://api.example.com/v1"))
                    .font(.body.monospaced())

                SecureField("API key", text: $apiKey)

                TextField("Model ID (optional)", text: $modelID, prompt: Text("Choose later from the model list"))
                    .font(.body.monospaced())
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(actionTitle) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmedForInput.isEmpty || baseURL.trimmedForInput.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 500)
    }

    private var title: String {
        switch mode {
        case .add: return "Add a Provider"
        case .edit: return "Edit Provider"
        }
    }

    private var actionTitle: String {
        switch mode {
        case .add: return "Add Provider"
        case .edit: return "Save Changes"
        }
    }

    private func save() {
        do {
            let profile: CustomProviderProfile
            switch mode {
            case .add:
                profile = try model.addCustomProvider(label: name, baseURL: baseURL)
            case .edit(let existing):
                profile = try model.updateCustomProvider(existing, label: name, baseURL: baseURL)
            }

            let key = apiKey.trimmedForInput
            if !key.isEmpty, !KeychainManager.saveKey(key, for: profile.id) {
                errorMessage = "The provider was saved, but the Keychain did not accept the key. Enter it again."
                return
            }

            let chosen = modelID.trimmedForInput
            if !chosen.isEmpty {
                model.settings.select(model: chosen, forProvider: profile.id)
            }

            model.selectProvider(profile.id)
            onSaved(profile.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
