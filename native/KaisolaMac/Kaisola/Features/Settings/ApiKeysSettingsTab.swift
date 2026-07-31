import SwiftUI

/// Settings ▸ Models & Keys: direct-API credentials plus non-secret routing
/// for Anthropic and OpenAI agent terminals/chats.
///
/// Stored values are never shown. Each row reports only "set" or "not set";
/// typing a new value and pressing Save overwrites the stored key, and Clear
/// deletes it. Electron parity: Settings ▸ Models & keys, where the renderer can
/// set / probe / clear a key but never read it back.
struct ApiKeysSettingsTab: View {
    private let store: ApiKeyStore
    @ObservedObject private var settings: NativePreviewSettings
    @State private var selectedProvider = DirectAPIProvider.anthropic

    init(
        store: ApiKeyStore = ApiKeyStore(),
        settings: NativePreviewSettings = .shared
    ) {
        self.store = store
        self.settings = settings
    }

    var body: some View {
        Form {
            Section("Direct API Keys") {
                ForEach(ApiKeyStore.Key.allCases, id: \.self) { key in
                    ApiKeyRow(store: store, key: key)
                }
                Text("Stored in this Mac's Keychain and injected only into new direct-API agent terminals and chats. CLI sign-ins do not use these keys; stored values are never displayed.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Kaisola checks the key's shape locally. The provider verifies it when a new direct-API session starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Provider Routing") {
                LabeledContent("Provider") {
                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(DirectAPIProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .accessibilityLabel("Provider routing")
                }

                LabeledContent("Base URL") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "\(selectedProvider.title) base URL",
                            text: baseURLBinding,
                            prompt: Text("Provider default")
                        )
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("\(selectedProvider.title) base URL")
                        if let issue = ProviderRouting.baseURLIssue(baseURLBinding.wrappedValue) {
                            Label(issue, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                LabeledContent("Model") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "\(selectedProvider.title) model",
                            text: modelBinding,
                            prompt: Text("Provider default")
                        )
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("\(selectedProvider.title) model")
                        if let issue = ProviderRouting.modelIssue(modelBinding.wrappedValue) {
                            Label(issue, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                LabeledContent {
                    Button("Use Provider Defaults", action: resetSelectedProvider)
                        .disabled(
                            baseURLBinding.wrappedValue.isEmpty
                                && modelBinding.wrappedValue.isEmpty
                        )
                } label: {
                    Text("")
                }

                Text(routingDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(6)
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: {
                selectedProvider == .anthropic
                    ? settings.anthropicBaseURL
                    : settings.openAIBaseURL
            },
            set: { value in
                if selectedProvider == .anthropic {
                    settings.anthropicBaseURL = value
                } else {
                    settings.openAIBaseURL = value
                }
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: {
                selectedProvider == .anthropic
                    ? settings.anthropicModel
                    : settings.openAIModel
            },
            set: { value in
                if selectedProvider == .anthropic {
                    settings.anthropicModel = value
                } else {
                    settings.openAIModel = value
                }
            }
        )
    }

    private var routingDetail: String {
        switch selectedProvider {
        case .anthropic:
            "New Claude sessions use these values; non-local routes require HTTPS."
        case .openAI:
            "New Codex sessions and Mesh use these values; config.toml is never rewritten."
        }
    }

    private func resetSelectedProvider() {
        if selectedProvider == .anthropic {
            settings.anthropicBaseURL = ""
            settings.anthropicModel = ""
        } else {
            settings.openAIBaseURL = ""
            settings.openAIModel = ""
        }
    }
}

/// A deliberately soft, local-only check. Prefixes catch common paste mistakes
/// without pretending the provider accepted the credential; saving remains
/// available because providers may add legitimate formats over time.
enum ApiKeyFormatPolicy {
    static func warning(for key: ApiKeyStore.Key, value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) {
            return "API keys normally do not contain spaces or line breaks."
        }
        switch key {
        case .anthropic where !trimmed.hasPrefix("sk-ant-"):
            return "Anthropic API keys usually begin with sk-ant-."
        case .openai where !trimmed.hasPrefix("sk-"):
            return "OpenAI API keys usually begin with sk-."
        default:
            break
        }
        if trimmed.count < 20 {
            return "This API key looks unusually short."
        }
        return nil
    }
}

/// One provider row: a masked field that starts empty (the stored value is never
/// loaded into it), a set/not-set caption, Save, and Clear.
private struct ApiKeyRow: View {
    let store: ApiKeyStore
    let key: ApiKeyStore.Key

    @State private var draft = ""
    @State private var isSet = false
    @State private var errorText: String?
    @State private var savedFormatWarning: String?
    @State private var showsClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(
                    isSet ? "Saved — enter a new key to replace" : "Not set",
                    text: $draft
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .accessibilityLabel("\(key.title) API key")
                Button("Save", action: save)
                    .disabled(trimmedDraft.isEmpty)
                    .accessibilityLabel("Save \(key.title) API key")
                if isSet {
                    Button("Clear", role: .destructive) { showsClearConfirmation = true }
                        .accessibilityLabel("Clear \(key.title) API key")
                }
            }
            HStack(spacing: 4) {
                Image(systemName: isSet ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isSet ? Color.green : Color.secondary)
                Text(isSet ? "\(key.rawValue) is set" : "\(key.rawValue) is not set")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let warning = visibleFormatWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        // The row label; the field/status stack sits in the value column.
        .modifier(RowLabel(title: key.title))
        .onAppear(perform: refresh)
        .confirmationDialog(
            "Clear \(key.title) API Key?",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear API Key", role: .destructive, action: clear)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New direct-API sessions will stop receiving this key. Existing provider sign-ins are not affected.")
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var draftFormatWarning: String? {
        guard !trimmedDraft.isEmpty else { return nil }
        return ApiKeyFormatPolicy.warning(for: key, value: draft)
    }

    private var visibleFormatWarning: String? {
        trimmedDraft.isEmpty ? savedFormatWarning : draftFormatWarning
    }

    private func refresh() {
        // Visual/accessibility fixtures must be deterministic and must never
        // touch or reveal the developer's real Keychain state.
        guard ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] != "1" else {
            isSet = false
            savedFormatWarning = nil
            return
        }
        let stored = store.read(key)
        isSet = stored != nil
        savedFormatWarning = stored.flatMap { ApiKeyFormatPolicy.warning(for: key, value: $0) }
    }

    private func save() {
        guard !trimmedDraft.isEmpty else { return }
        errorText = nil
        do {
            try store.write(key, value: draft)
            draft = ""
            refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func clear() {
        errorText = nil
        store.delete(key)
        draft = ""
        refresh()
    }
}

/// Puts the provider name in the Form's leading label column, wrapping the row
/// content in `LabeledContent` so it aligns with the rest of the settings form.
private struct RowLabel: ViewModifier {
    let title: String
    func body(content: Content) -> some View {
        LabeledContent {
            content
        } label: {
            Text(title)
        }
    }
}
