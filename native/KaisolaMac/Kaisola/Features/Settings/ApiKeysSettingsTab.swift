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
                    ApiKeyRow(
                        store: store,
                        key: key,
                        configuredBaseURL: key == .anthropic
                            ? settings.anthropicBaseURL
                            : settings.openAIBaseURL
                    )
                }
                Text("Stored in this Mac's Keychain and injected only into new direct-API agent terminals and chats. CLI sign-ins do not use these keys; stored values are never displayed.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Testing makes a bounded authenticated model-list request without sending a prompt. You can test a newly pasted key before saving it or verify the saved Keychain value later.")
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
                                .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
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
                                .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
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

/// Result of a no-prompt provider credential check. Symbols and text accompany
/// every color in the UI, so rejected credentials and transient connectivity
/// failures remain distinguishable without relying on hue.
struct ApiKeyProbeResult: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case ready
        case rejected
        case failed
    }

    let status: Status
    let message: String
}

/// Performs one cheap authenticated GET against the provider's model-list
/// endpoint. The production session is ephemeral, refuses redirects so a key
/// cannot follow an unreviewed Location, and accepts only a small JSON object.
actor ApiKeyProbeService {
    static let shared = ApiKeyProbeService(session: URLSession(
        configuration: .ephemeral,
        delegate: ApiKeyNoRedirectSessionDelegate(),
        delegateQueue: nil
    ))

    private static let maximumResponseBytes = 256 * 1_024
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func probe(
        key: ApiKeyStore.Key,
        value: String,
        configuredBaseURL: String
    ) async -> ApiKeyProbeResult {
        let credential = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else {
            return .init(status: .failed, message: "Enter or save an API key first.")
        }
        guard let url = Self.modelsURL(for: key, configuredBaseURL: configuredBaseURL) else {
            return .init(status: .failed, message: "Fix the provider Base URL before testing.")
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 4.5
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        switch key {
        case .anthropic:
            request.setValue(credential, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openai:
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .init(status: .failed, message: "The provider returned a non-HTTP response.")
            }
            switch http.statusCode {
            case 200..<300:
                guard data.count <= Self.maximumResponseBytes else {
                    return .init(status: .failed, message: "The provider response exceeded 256 KB.")
                }
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["data"] is [Any] else {
                    return .init(status: .failed, message: "The provider returned an unexpected response.")
                }
                return .init(status: .ready, message: "Verified with \(key.title).")
            case 401, 403:
                return .init(status: .rejected, message: "\(key.title) rejected this API key.")
            case 429:
                return .init(status: .failed, message: "\(key.title) is rate limiting checks. Try again later.")
            default:
                return .init(status: .failed, message: "\(key.title) returned HTTP \(http.statusCode).")
            }
        } catch is CancellationError {
            return .init(status: .failed, message: "The API key check was cancelled.")
        } catch let error as URLError where error.code == .timedOut {
            return .init(status: .failed, message: "The API key check timed out after 4.5 seconds.")
        } catch {
            return .init(status: .failed, message: "Could not connect to \(key.title).")
        }
    }

    /// Visible to focused tests so provider-specific path construction cannot
    /// drift into a paid prompt endpoint. Custom base URLs use the same routing
    /// validation as new agent sessions.
    static func modelsURL(
        for key: ApiKeyStore.Key,
        configuredBaseURL: String
    ) -> URL? {
        let configured = configuredBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBase: String
        if configured.isEmpty {
            rawBase = key == .anthropic
                ? "https://api.anthropic.com"
                : "https://api.openai.com/v1"
        } else {
            guard ProviderRouting.baseURLIssue(configured) == nil,
                  let normalized = ProviderRouting.normalizedBaseURL(configured) else { return nil }
            rawBase = normalized
        }
        guard var components = URLComponents(string: rawBase),
              components.query == nil,
              components.fragment == nil else { return nil }
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if key == .anthropic, path.split(separator: "/").last != "v1" {
            path += "/v1"
        } else if key == .openai, path.isEmpty {
            path = "/v1"
        }
        path += "/models"
        components.path = path
        if key == .anthropic {
            components.queryItems = [URLQueryItem(name: "limit", value: "1")]
        }
        return components.url
    }
}

private final class ApiKeyNoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// One provider row: a masked field that starts empty (the stored value is never
/// loaded into it), a set/not-set caption, Save, and Clear.
private struct ApiKeyRow: View {
    let store: ApiKeyStore
    let key: ApiKeyStore.Key
    let configuredBaseURL: String

    @State private var draft = ""
    @State private var isSet = false
    @State private var errorText: String?
    @State private var savedFormatWarning: String?
    @State private var showsClearConfirmation = false
    @State private var isTesting = false
    @State private var probeResult: ApiKeyProbeResult?
    @State private var probeTask: Task<Void, Never>?

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
                Button {
                    testCredential()
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Test")
                    }
                }
                .disabled(isTesting || (trimmedDraft.isEmpty && !isSet))
                .accessibilityLabel("Test \(key.title) API key")
                if isSet {
                    Button("Clear", role: .destructive) { showsClearConfirmation = true }
                        .accessibilityLabel("Clear \(key.title) API key")
                }
            }
            HStack(spacing: 4) {
                Image(systemName: isSet ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(
                        isSet
                            ? KaisolaStatusTone.done.foregroundColor
                            : Color.secondary
                    )
                Text(isSet ? "\(key.rawValue) is set" : "\(key.rawValue) is not set")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
            }
            if let warning = visibleFormatWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
            }
            if let probeResult {
                Label(probeResult.message, systemImage: probeSymbol(probeResult.status))
                    .font(.caption)
                    .foregroundStyle(probeColor(probeResult.status))
                    .accessibilityLabel(probeResult.message)
            }
        }
        // The row label; the field/status stack sits in the value column.
        .modifier(RowLabel(title: key.title))
        .onAppear(perform: refresh)
        .onChange(of: draft) { _, _ in invalidateProbe() }
        .onChange(of: configuredBaseURL) { _, _ in invalidateProbe() }
        .onDisappear(perform: invalidateProbe)
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
        probeResult = nil
        refresh()
    }

    private func testCredential() {
        let candidate = trimmedDraft.isEmpty ? store.read(key) : trimmedDraft
        guard let candidate, !candidate.isEmpty else { return }
        probeTask?.cancel()
        probeResult = nil
        isTesting = true
        let baseURL = configuredBaseURL
        probeTask = Task {
            let result = await ApiKeyProbeService.shared.probe(
                key: key,
                value: candidate,
                configuredBaseURL: baseURL
            )
            guard !Task.isCancelled else { return }
            probeResult = result
            isTesting = false
            probeTask = nil
        }
    }

    private func invalidateProbe() {
        probeTask?.cancel()
        probeTask = nil
        isTesting = false
        probeResult = nil
    }

    private func probeSymbol(_ status: ApiKeyProbeResult.Status) -> String {
        switch status {
        case .ready: "checkmark.seal.fill"
        case .rejected: "xmark.octagon.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func probeColor(_ status: ApiKeyProbeResult.Status) -> Color {
        switch status {
        case .ready: .green
        case .rejected: .red
        case .failed: .orange
        }
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
