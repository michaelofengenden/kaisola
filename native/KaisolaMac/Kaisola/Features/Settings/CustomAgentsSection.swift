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
/// Terminal launch stays independent. An optional ACP package reaches chat only
/// after its exact install, credential context, and containment privileges are
/// reviewed together.
struct CustomAgentsSection: View {
    private let store = CustomAgentStore()
    /// A small, curated set so every custom agent gets a recognizable glyph.
    private let symbolChoices = ["terminal", "cpu", "bolt", "ant", "bird", "cloud"]
    private let cap = 12

    @State private var specs: [CustomAgentSpec] = []
    @State private var newName = ""
    @State private var newCommand = ""
    /// Which row's honest-grant confirmation is open.
    @State private var pendingEnableIndex: Int?
    /// The agent whose pinned install is currently running.
    @State private var installingAgentID: String?
    private let installs = AdapterInstallManager()

    var body: some View {
        Section("Custom Agents") {
            if specs.isEmpty {
                Text("Add any terminal CLI — it appears in the New menu and launches into an owned terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(specs.enumerated()), id: \.offset) { index, spec in
                VStack(alignment: .leading, spacing: 5) {
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
                        .disabled(installingAgentID == spec.id)
                    }
                    acpControls(index: index, spec: spec)
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
                Text("Terminal commands use the user's shell. Optional chat adapters run separately under a reviewed sandbox grant.")
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
            id: CustomAgentStore.slugify(name, existing: Set(specs.map(\.id))),
            name: name,
            launchCommand: command,
            symbol: symbolChoices.first ?? "terminal",
            acpPrivileges: []
        ))
        store.save(specs)
        specs = store.all()   // reflect the store's cap
        newName = ""
        newCommand = ""
        NotificationCenter.default.post(name: .kaisolaAgentsChanged, object: nil)
    }

    private func delete(_ index: Int) {
        guard specs.indices.contains(index) else { return }
        installs.uninstall(agentID: specs[index].id)
        specs.remove(at: index)
        if pendingEnableIndex == index {
            pendingEnableIndex = nil
        } else if let pendingEnableIndex, pendingEnableIndex > index {
            self.pendingEnableIndex = pendingEnableIndex - 1
        }
        persist()
    }

    /// Save the current list and announce the change so menus rebuild.
    private func persist() {
        store.save(specs)
        NotificationCenter.default.post(name: .kaisolaAgentsChanged, object: nil)
    }

    // MARK: - Chat surface (ACP adapter)

    /// The per-agent ACP block: declare a package and a credential context,
    /// then enable the chat surface through the pinned-install approval flow.
    /// Every state names itself — invalid package, install failure, drift.
    @ViewBuilder
    private func acpControls(index: Int, spec: CustomAgentSpec) -> some View {
        let hasReviewedAccess = spec.containmentApproval != nil
        let locksContract = spec.chatEnabled == true && hasReviewedAccess
        HStack(spacing: 8) {
            TextField("ACP adapter (npm package, optional)", text: packageBinding(index))
                .font(.caption.monospaced())
                .textFieldStyle(.plain)
                .disabled(locksContract)
            Picker("", selection: credentialsBinding(index)) {
                ForEach(CustomAgentSpec.Credentials.allCases) { credentials in
                    Text(credentials.title).tag(credentials.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 150)
            .disabled(locksContract)
            if locksContract {
                Button("Disable Chat") { disableChat(index) }
                    .font(.caption)
            } else if spec.acpPackage?.isEmpty == false, spec.acpPackageValidationError == nil {
                Button(installingAgentID == spec.id
                    ? "Installing…"
                    : (spec.chatEnabled == true ? "Review Access…" : "Enable Chat…")) {
                    beginEnable(index)
                }
                .font(.caption)
                .disabled(installingAgentID != nil)
            }
        }
        if spec.acpPackage?.isEmpty == false {
            VStack(alignment: .leading, spacing: 4) {
                Text("Contained access")
                    .font(.caption.weight(.medium))
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: 12, alignment: .leading)],
                    alignment: .leading,
                    spacing: 4
                ) {
                    ForEach(CustomAdapterPrivilege.allCases) { privilege in
                        Toggle(privilege.title, isOn: privilegeBinding(index, privilege))
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .disabled(locksContract)
                            .help(privilege.reviewDetail)
                    }
                }
                if let approval = spec.containmentApproval {
                    Text(approval.reviewSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        if let reason = spec.acpPackageValidationError {
            Text(reason).font(.caption).foregroundStyle(.orange)
        } else if let issue = spec.containmentIssue, spec.acpPackage?.isEmpty == false {
            Text("Chat disabled: \(issue)").font(.caption).foregroundStyle(.orange)
        } else if spec.chatEnabled == true, let approval = spec.containmentApproval {
            switch installs.verify(
                agentID: spec.id,
                expectedPackage: spec.acpPackage,
                expectedApproval: approval
            ) {
            case let .verified(binURL, _):
                let version = installs.store.record(agentID: spec.id)?.resolvedVersion ?? "?"
                Text("Chat enabled · \(spec.acpPackage ?? "") v\(version) · contained \(binURL.lastPathComponent) · \(approval.reviewSummary)")
                    .font(.caption).foregroundStyle(.secondary)
            case let .drifted(reason):
                Text("Chat disabled: \(reason) Re-enable to approve the current version.")
                    .font(.caption).foregroundStyle(.orange)
            case .notInstalled:
                Text("Chat disabled: the approved install is gone. Re-enable to install again.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        if pendingEnableIndex == index {
            // The exact grant remains visible before installation and, through
            // the status line above, for the lifetime of the approval.
            VStack(alignment: .leading, spacing: 6) {
                Text("Enabling installs \(spec.acpPackage ?? "") with install scripts disabled, pins its exact dependency graph, and runs the pinned JavaScript under Kaisola's sealed Node runtime and a deny-by-default macOS sandbox. Reviewed grant: \(spec.containmentApproval?.reviewSummary ?? "invalid — choose access above"). Process/network grants also share the matching enabled workspace MCP definitions, including their configured environment/header values. Unrelated process-environment credentials, your ordinary home files, local Unix sockets, inbound network, and Kaisola's host terminal bridge stay blocked. Install or access changes disable chat until you approve again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Install and Enable") { enableChat(index) }
                        .font(.caption)
                    Button("Cancel") { pendingEnableIndex = nil }
                        .font(.caption)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func packageBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { specs.indices.contains(index) ? (specs[index].acpPackage ?? "") : "" },
            set: { newValue in
                guard specs.indices.contains(index) else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                specs[index].acpPackage = trimmed.isEmpty ? nil : trimmed
                persist()
            }
        )
    }

    private func credentialsBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                specs.indices.contains(index)
                    ? specs[index].resolvedCredentials.rawValue
                    : CustomAgentSpec.Credentials.none.rawValue
            },
            set: { newValue in
                guard specs.indices.contains(index) else { return }
                specs[index].credentials = newValue
                persist()
            }
        )
    }

    private func privilegeBinding(
        _ index: Int,
        _ privilege: CustomAdapterPrivilege
    ) -> Binding<Bool> {
        Binding(
            get: {
                guard specs.indices.contains(index) else { return false }
                return specs[index].acpPrivileges?.contains(privilege.rawValue) == true
            },
            set: { enabled in
                guard specs.indices.contains(index) else { return }
                var privileges = Set(specs[index].acpPrivileges ?? [])
                if enabled {
                    privileges.insert(privilege.rawValue)
                } else {
                    privileges.remove(privilege.rawValue)
                }
                specs[index].acpPrivileges = CustomAdapterPrivilege.allCases
                    .filter { privileges.contains($0.rawValue) }
                    .map(\.rawValue)
                persist()
            }
        )
    }

    private func beginEnable(_ index: Int) {
        guard specs.indices.contains(index) else { return }
        // A legacy pre-containment enablement is not an approval. Drop its old
        // install before opening the new review so no stale record can satisfy
        // the resolver while the user is choosing a grant.
        if specs[index].chatEnabled == true, specs[index].containmentApproval == nil {
            installs.uninstall(agentID: specs[index].id)
            specs[index].chatEnabled = false
        }
        if specs[index].acpPrivileges == nil { specs[index].acpPrivileges = [] }
        persist()
        pendingEnableIndex = index
    }

    private func enableChat(_ index: Int) {
        guard specs.indices.contains(index),
              let package = specs[index].acpPackage,
              let approval = specs[index].containmentApproval else {
            ToastCenter.shared.show(
                "Review the adapter's contained access before enabling chat.",
                style: .error
            )
            return
        }
        let agentID = specs[index].id
        pendingEnableIndex = nil
        installingAgentID = agentID
        Task { @MainActor in
            defer { installingAgentID = nil }
            do {
                let record = try await installs.install(
                    agentID: agentID,
                    package: package,
                    approval: approval
                )
                if let liveIndex = specs.firstIndex(where: { $0.id == agentID }) {
                    specs[liveIndex].chatEnabled = true
                    persist()
                }
                ToastCenter.shared.show(
                    "\(package) v\(record.resolvedVersion) installed, pinned, and contained. Chat is enabled.",
                    style: .success
                )
            } catch {
                ToastCenter.shared.show(error.localizedDescription, style: .error, duration: 6)
            }
        }
    }

    private func disableChat(_ index: Int) {
        guard specs.indices.contains(index) else { return }
        let agentID = specs[index].id
        installs.uninstall(agentID: agentID)
        specs[index].chatEnabled = false
        persist()
    }
}
