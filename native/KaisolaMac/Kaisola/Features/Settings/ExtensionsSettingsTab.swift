import AppKit
import SwiftUI

/// Settings ▸ Extensions: the custom-grammar registry and its health. Grammars
/// are data only, so this pane's whole job is to say which ones are installed,
/// why an invalid one is not, and — when the registry itself cannot be read —
/// where the preserved copy went, what stays read-only, and how to start over
/// without losing that copy.
struct ExtensionsSettingsTab: View {
    private let store: CustomGrammarStore

    @State private var snapshot: CustomGrammarStore.Snapshot
    /// The reason the last remove or reset was refused, shown until the next one.
    @State private var actionError: String?

    init(store: CustomGrammarStore = CustomGrammarStore()) {
        self.store = store
        _snapshot = State(initialValue: CustomGrammarStore.Snapshot(specs: [], state: .absent))
    }

    var body: some View {
        Form {
            registrySection
            grammarsSection
        }
        .formStyle(.grouped)
        .padding(6)
        .onAppear { reload() }
    }

    // MARK: - Registry health

    @ViewBuilder
    private var registrySection: some View {
        Section("Grammar Registry") {
            if let notice = ExtensionsSettingsPolicy.registryNotice(for: snapshot.state) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(notice.title, systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.semibold))
                    Text(notice.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        if let preserved = notice.preservedCopy {
                            Button("Show Preserved Copy") { reveal(preserved) }
                        }
                        Button("Reset Registry", role: .destructive) { resetRegistry() }
                            .disabled(!notice.canReset)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 2)
            } else {
                Text(ExtensionsSettingsPolicy.healthySummary(for: snapshot.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("File") {
                Button(store.fileURL.path) { reveal(store.fileURL) }
                    .buttonStyle(.link)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Installed grammars

    @ViewBuilder
    private var grammarsSection: some View {
        Section("Custom Grammars") {
            if snapshot.specs.isEmpty {
                Text("No custom grammars. Add them to custom-grammars.json — extensions, fence tokens, and regex rules over the five color roles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshot.specs) { spec in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(spec.title).font(.callout)
                            Text(spec.normalizedExtensions.map { ".\($0)" }.joined(separator: " "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) { remove(spec) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!snapshot.state.allowsWrites)
                        .accessibilityLabel("Remove \(spec.title)")
                    }
                    if let reason = spec.validationError {
                        Text("Disabled — \(reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        snapshot = store.load()
    }

    private func remove(_ spec: CustomGrammarSpec) {
        do {
            _ = try store.remove(id: spec.id)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
        reload()
    }

    private func resetRegistry() {
        do {
            snapshot = try store.resetUnreadableRegistry()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
            reload()
        }
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Pure presentation policy for the registry banner, shared by the view and
/// focused tests. Every sentence a user can be shown about a quarantined
/// registry is decided here, including where the preserved copy landed.
enum ExtensionsSettingsPolicy {
    struct RegistryNotice: Equatable {
        var title: String
        var message: String
        var preservedCopy: URL?
        var canReset: Bool
    }

    static func registryNotice(for state: CustomGrammarStore.LoadState) -> RegistryNotice? {
        switch state {
        case .absent, .ready:
            nil
        case let .malformed(preserved):
            RegistryNotice(
                title: "The custom-grammar registry could not be read",
                message: "\(preservationSentence(preserved)) Custom grammars stay read-only until you reset the registry, so nothing overwrites the file in the meantime.",
                preservedCopy: preserved.url,
                canReset: state.canReset
            )
        case let .newerSchema(version, preserved):
            RegistryNotice(
                title: "The custom-grammar registry comes from a newer Kaisola",
                message: "This build reads registry version \(CustomGrammarStore.schemaVersion); the file on disk is version \(version). \(preservationSentence(preserved)) Update Kaisola to use these grammars, or reset the registry to start over here.",
                preservedCopy: preserved.url,
                canReset: state.canReset
            )
        case let .unreadable(reason):
            RegistryNotice(
                title: "The custom-grammar registry could not be opened",
                message: "\(reason) Custom grammars stay read-only until the file can be read again.",
                preservedCopy: nil,
                canReset: false
            )
        }
    }

    static func healthySummary(for state: CustomGrammarStore.LoadState) -> String {
        switch state {
        case .absent:
            "No registry file yet. One is written the first time a custom grammar is saved."
        case let .ready(version):
            "Registry version \(version) read normally."
        case .malformed, .newerSchema, .unreadable:
            ""
        }
    }

    private static func preservationSentence(_ preserved: CustomGrammarStore.PreservedCopy) -> String {
        switch preserved {
        case let .saved(url):
            "The file was preserved, byte for byte, at \(url.path)."
        case let .failed(reason):
            "Kaisola could not preserve a copy of the file: \(reason)"
        }
    }
}
