import SwiftUI

extension Notification.Name {
    /// Posted whenever the custom-agent roster changes (add / remove / rename /
    /// icon). The File-menu agent submenu is built once at startup and is
    /// otherwise stale until relaunch, so the app delegate observes this to
    /// rebuild the menu; live SwiftUI pickers pick up the change on their next
    /// body evaluation.
    static let kaisolaAgentsChanged = Notification.Name("kaisolaAgentsChanged")
}

/// Settings ▸ Agents section for user-registered terminal agents (Electron
/// Settings ▸ Agents parity): list existing custom agents — name, launch
/// command, an SF-symbol picker, delete — plus an add row. Every mutation
/// persists through `CustomAgentStore` and posts `.kaisolaAgentsChanged`.
/// Terminal-only by construction: these agents have no ACP adapter, so they
/// never appear on chat surfaces.
struct CustomAgentsSection: View {
    private let store = CustomAgentStore()
    /// A small, curated set so every custom agent gets a recognizable glyph.
    private let symbolChoices = ["terminal", "cpu", "bolt", "ant", "bird", "cloud"]
    private let cap = 12

    @State private var specs: [CustomAgentSpec] = []
    @State private var newName = ""
    @State private var newCommand = ""

    var body: some View {
        Section("Custom agents") {
            if specs.isEmpty {
                Text("Add any terminal CLI — it appears in the New menu and launches into an owned terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(specs.enumerated()), id: \.offset) { index, spec in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(spec.name).font(.callout)
                        Text(spec.launchCommand)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Picker("", selection: symbolBinding(index)) {
                        ForEach(symbolChoices, id: \.self) { name in
                            Image(systemName: name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 64)
                    Button(role: .destructive) { delete(index) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Name", text: $newName)
                    .onSubmit(add)
                TextField("Command (e.g. aider)", text: $newCommand)
                    .font(.callout.monospaced())
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(!canAdd)
            }
            if specs.count >= cap {
                Text("Custom-agent limit reached (\(cap)).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Runs through a login shell like the built-in agents; terminal-only, no chat surface.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { specs = store.all() }
    }

    private var canAdd: Bool {
        specs.count < cap
            && !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !newCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A binding that persists an icon change and rebuilds menus on set.
    private func symbolBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { specs.indices.contains(index) ? specs[index].symbol : "terminal" },
            set: { newValue in
                guard specs.indices.contains(index) else { return }
                specs[index].symbol = newValue
                persist()
            }
        )
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = newCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty, specs.count < cap else { return }
        specs.append(CustomAgentSpec(
            id: CustomAgentStore.slugify(name),
            name: name,
            launchCommand: command,
            symbol: symbolChoices.first ?? "terminal"
        ))
        store.save(specs)
        specs = store.all()   // reflect the store's cap
        newName = ""
        newCommand = ""
        NotificationCenter.default.post(name: .kaisolaAgentsChanged, object: nil)
    }

    private func delete(_ index: Int) {
        guard specs.indices.contains(index) else { return }
        specs.remove(at: index)
        persist()
    }

    /// Save the current list and announce the change so menus rebuild.
    private func persist() {
        store.save(specs)
        NotificationCenter.default.post(name: .kaisolaAgentsChanged, object: nil)
    }
}
