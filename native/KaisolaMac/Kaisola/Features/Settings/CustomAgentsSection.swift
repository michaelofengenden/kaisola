import SwiftUI

extension Notification.Name {
    /// Posted whenever the custom-agent roster changes (add / remove / rename /
    /// icon). The File-menu agent submenu is built once at startup and is
    /// otherwise stale until relaunch, so the app delegate observes this to
    /// rebuild the menu; live SwiftUI pickers pick up the change on their next
    /// body evaluation.
    static let kaisolaAgentsChanged = Notification.Name("kaisolaAgentsChanged")
}

struct CustomAgentSymbolChoice: Equatable, Identifiable, Sendable {
    let symbolName: String
    let name: String

    var id: String { symbolName }
}

/// One source of truth for the compact symbol menu's visible glyphs and spoken
/// names. Keeping this outside the view makes it impossible for a new icon to
/// silently ship without a human-readable VoiceOver name.
enum CustomAgentSymbolAccessibility {
    static let choices: [CustomAgentSymbolChoice] = [
        CustomAgentSymbolChoice(symbolName: "terminal", name: "Terminal"),
        CustomAgentSymbolChoice(symbolName: "cpu", name: "Processor"),
        CustomAgentSymbolChoice(symbolName: "bolt", name: "Lightning bolt"),
        CustomAgentSymbolChoice(symbolName: "ant", name: "Ant"),
        CustomAgentSymbolChoice(symbolName: "bird", name: "Bird"),
        CustomAgentSymbolChoice(symbolName: "cloud", name: "Cloud"),
    ]

    static func pickerLabel(agentName: String) -> String {
        "Icon for \(agentName)"
    }

    static func currentValue(symbolName: String) -> String {
        choices.first { $0.symbolName == symbolName }?.name ?? "Unknown icon"
    }
}

/// Settings ▸ Agents section for user-registered terminal agents (Electron
/// Settings ▸ Agents parity): list existing custom agents — name, launch
/// command, an SF-symbol picker, delete — plus an add row. Every mutation
/// persists through `CustomAgentStore` and posts `.kaisolaAgentsChanged`.
/// Terminal launch stays independent. An optional ACP package reaches chat only
/// after its exact install, credential context, and containment privileges are
/// reviewed together.
struct CustomAgentsSection: View {
    var highlightedID: String? = nil
    private let store = CustomAgentStore()
    /// A small, curated set so every custom agent gets a recognizable glyph.
    private let symbolChoices = CustomAgentSymbolAccessibility.choices
    private let cap = 12

    @State private var specs: [CustomAgentSpec] = []
    @State private var newName = ""
    @State private var newCommand = ""
    /// Which row's honest-grant confirmation is open.
    @State private var pendingEnableIndex: Int?
    /// The agent whose pinned install is currently running.
    @State private var installingAgentID: String?
    /// Which row's delete confirmation is open.
    @State private var pendingDeleteID: String?
    /// A load or save failure stays visible in the section instead of making
    /// the registry look empty or a mutation look committed.
    @State private var registryError: String?
    @State private var loadBlocked = false
    private let installs = AdapterInstallManager()

    var body: some View {
        Section("Custom Agents") {
            if specs.isEmpty {
                Text("Add any terminal CLI — it appears in the New menu and launches into an owned terminal.")
                    .font(.caption).foregroundStyle(.kaisolaSecondary)
                    .accessibilityIdentifier("extensions.agents.empty")
            }
            if let registryError {
                Text(registryError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(specs.enumerated()), id: \.offset) { index, spec in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(spec.name).font(.callout)
                            Text(spec.launchCommand)
                                .font(.caption.monospaced()).foregroundStyle(.kaisolaSecondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Picker(
                            CustomAgentSymbolAccessibility.pickerLabel(agentName: spec.name),
                            selection: symbolBinding(index)
                        ) {
                            ForEach(symbolChoices) { choice in
                                Image(systemName: choice.symbolName)
                                    .accessibilityLabel(choice.name)
                                    .tag(choice.symbolName)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 64)
                        .accessibilityLabel(
                            CustomAgentSymbolAccessibility.pickerLabel(agentName: spec.name)
                        )
                        .accessibilityValue(
                            CustomAgentSymbolAccessibility.currentValue(symbolName: spec.symbol)
                        )
                        .accessibilityIdentifier("extensions.agent.\(spec.id).icon")
                        .help(
                            "\(CustomAgentSymbolAccessibility.pickerLabel(agentName: spec.name)): "
                                + CustomAgentSymbolAccessibility.currentValue(symbolName: spec.symbol)
                        )
                        Button(role: .destructive) { pendingDeleteID = spec.id } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove custom agent \(spec.name)")
                        .disabled(loadBlocked || installingAgentID == spec.id)
                    }
                    acpControls(index: index, spec: spec)
                    ExtensionMetadataGrid(
                        item: .customAgent(
                            spec,
                            install: installs.store.record(agentID: spec.id)
                        )
                    )
                    deleteConfirmation(spec: spec)
                }
                .padding(.vertical, 4)
                .id(spec.id)
                .overlay {
                    if highlightedID == spec.id {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("extensions.agent.\(spec.id)")
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
                    .font(.caption).foregroundStyle(.kaisolaSecondary)
            } else {
                Text("Terminal commands use the user's shell. Optional chat adapters run separately under a reviewed sandbox grant.")
                    .font(.caption).foregroundStyle(.kaisolaSecondary)
            }
        }
        .onAppear(perform: load)
    }

    private var canAdd: Bool {
        !loadBlocked
            && specs.count < cap
            && !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !newCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A binding that persists an icon change and rebuilds menus on set.
    private func symbolBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { specs.indices.contains(index) ? specs[index].symbol : "terminal" },
            set: { newValue in
                guard specs.indices.contains(index) else { return }
                let previous = specs
                specs[index].symbol = newValue
                persist(affectedAgentID: specs[index].id, restoring: previous)
            }
        )
    }

    private func load() {
        switch store.load() {
        case let .success(loaded):
            specs = loaded
            registryError = nil
            loadBlocked = false
        case let .failure(error):
            specs = []
            registryError = error.localizedDescription
            loadBlocked = true
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = newCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !loadBlocked, !name.isEmpty, !command.isEmpty, specs.count < cap else { return }
        let previous = specs
        let added = CustomAgentSpec(
            id: CustomAgentStore.slugify(name, existing: Set(specs.map(\.id))),
            name: name,
            launchCommand: command,
            symbol: symbolChoices.first?.symbolName ?? "terminal",
            acpPrivileges: []
        )
        specs.append(added)
        if persist(affectedAgentID: added.id, restoring: previous) {
            newName = ""
            newCommand = ""
        }
    }

    private var deletion: CustomAgentDeletion {
        CustomAgentDeletion(store: store, installs: installs)
    }

    /// The delete confirmation for one row: it names the agent and, when the
    /// agent has a pinned adapter, the exact version that leaves disk with it.
    /// Deleting used to drop the roster entry on the first click and leave the
    /// install behind with no owner and no cleanup route. The plan is read on
    /// each body pass, so enabling chat while this is open cannot leave the
    /// sentence claiming there is nothing to remove.
    @ViewBuilder
    private func deleteConfirmation(spec: CustomAgentSpec) -> some View {
        if pendingDeleteID == spec.id {
            let plan = deletion.plan(for: spec)
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Delete", role: .destructive) { confirmDelete(plan) }
                        .font(.caption)
                    Button("Cancel") { pendingDeleteID = nil }
                        .font(.caption)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Remove the pinned install and the roster entry as one step. A failure
    /// leaves both in place and says so, so the agent stays deletable.
    private func confirmDelete(_ plan: CustomAgentDeletion.Plan) {
        pendingDeleteID = nil
        let previous = specs
        let removedIndex = specs.firstIndex { $0.id == plan.agentID }
        do {
            specs = try deletion.delete(agentID: plan.agentID, from: specs)
            registryError = nil
            if pendingEnableIndex == removedIndex {
                pendingEnableIndex = nil
            } else if let pendingEnableIndex, let removedIndex,
                      pendingEnableIndex > removedIndex {
                self.pendingEnableIndex = pendingEnableIndex - 1
            }
            NotificationCenter.default.post(name: .kaisolaAgentsChanged, object: nil)
            NotificationCenter.default.post(name: .kaisolaExtensionsChanged, object: nil)
        } catch {
            specs = previous
            registryError = error.localizedDescription
            ToastCenter.shared.show(error.localizedDescription, style: .error, duration: 6)
        }
    }

    /// Save the current list and announce only a committed change. On failure,
    /// restore the exact UI state that still exists on disk and name the
    /// affected entry in both the section and a toast.
    @discardableResult
    private func persist(
        affectedAgentID: String?,
        restoring previous: [CustomAgentSpec]
    ) -> Bool {
        switch store.save(specs, affectedAgentID: affectedAgentID) {
        case let .success(saved):
            specs = saved
            registryError = nil
            NotificationCenter.default.post(name: .kaisolaAgentsChanged, object: nil)
            NotificationCenter.default.post(name: .kaisolaExtensionsChanged, object: nil)
            return true
        case let .failure(error):
            specs = previous
            registryError = error.localizedDescription
            ToastCenter.shared.show(error.localizedDescription, style: .error, duration: 6)
            return false
        }
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
                        .foregroundStyle(.kaisolaSecondary)
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
                    .font(.caption).foregroundStyle(.kaisolaSecondary)
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
                    .foregroundStyle(.kaisolaSecondary)
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
                let previous = specs
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                specs[index].acpPackage = trimmed.isEmpty ? nil : trimmed
                persist(affectedAgentID: specs[index].id, restoring: previous)
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
                let previous = specs
                specs[index].credentials = newValue
                persist(affectedAgentID: specs[index].id, restoring: previous)
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
                let previous = specs
                var privileges = Set(specs[index].acpPrivileges ?? [])
                if enabled {
                    privileges.insert(privilege.rawValue)
                } else {
                    privileges.remove(privilege.rawValue)
                }
                specs[index].acpPrivileges = CustomAdapterPrivilege.allCases
                    .filter { privileges.contains($0.rawValue) }
                    .map(\.rawValue)
                persist(affectedAgentID: specs[index].id, restoring: previous)
            }
        )
    }

    private func beginEnable(_ index: Int) {
        guard specs.indices.contains(index) else { return }
        let previous = specs
        let agentID = specs[index].id
        // A legacy pre-containment enablement is not an approval. Drop its old
        // install before opening the new review so no stale record can satisfy
        // the resolver while the user is choosing a grant.
        let removesLegacyInstall = specs[index].chatEnabled == true
            && specs[index].containmentApproval == nil
        if removesLegacyInstall {
            specs[index].chatEnabled = false
        }
        if specs[index].acpPrivileges == nil { specs[index].acpPrivileges = [] }
        if persist(affectedAgentID: agentID, restoring: previous) {
            if removesLegacyInstall { installs.uninstall(agentID: agentID) }
            pendingEnableIndex = index
        }
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
                    let previous = specs
                    specs[liveIndex].chatEnabled = true
                    guard persist(affectedAgentID: agentID, restoring: previous) else {
                        installs.uninstall(agentID: agentID)
                        return
                    }
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
        let previous = specs
        specs[index].chatEnabled = false
        if persist(affectedAgentID: agentID, restoring: previous) {
            installs.uninstall(agentID: agentID)
        }
    }
}

/// Deleting a custom agent, as a value the settings row can confirm against
/// and a test can drive without a settings window.
///
/// A chat-enabled agent owns two things: its roster entry and a pinned adapter
/// install under `acp-adapters/<agentID>/`. Deleting only the entry stranded
/// the install — executable code on disk that nothing in the UI named or could
/// clean up. So the plan states both before the click, and the removal takes
/// them together.
struct CustomAgentDeletion {
    /// One agent's removal, described before it happens.
    struct Plan: Equatable {
        let agentID: String
        let agentName: String
        /// The pinned adapter as the confirmation says it, e.g.
        /// "probe-acp v1.2.3", or nil when the agent has no install.
        let pinnedInstall: String?

        /// The confirmation sentence. It always names the agent, and names the
        /// pinned adapter version whenever deleting would remove one.
        var message: String {
            guard let pinnedInstall else {
                return "Delete “\(agentName)”? It leaves the New menu; there is no pinned adapter install to remove."
            }
            return "Delete “\(agentName)”? Its pinned adapter install \(pinnedInstall) is removed from disk with it."
        }
    }

    /// A deletion that could not finish. It names the agent, the reason, and
    /// the fact that nothing was removed, so the user can retry.
    enum Failure: LocalizedError, Equatable {
        case installNotRemoved(agent: String, reason: String)
        case registryNotRemoved(agent: String, reason: String)
        case rollbackIncomplete(agent: String, reason: String)

        var errorDescription: String? {
            switch self {
            case let .installNotRemoved(agent, reason):
                "“\(agent)” was not deleted: its pinned adapter install could not be removed (\(reason)). Nothing changed — try again once the install directory is writable."
            case let .registryNotRemoved(agent, reason):
                "“\(agent)” was not deleted: its registry entry could not be saved (\(reason)). Its pinned adapter install was restored; try again."
            case let .rollbackIncomplete(agent, reason):
                "“\(agent)” could not be deleted safely, and rollback was incomplete (\(reason)). Restart Kaisola before retrying."
            }
        }
    }

    let store: CustomAgentStore
    let installs: AdapterInstallManager

    /// What deleting `spec` would remove, read from the recorded install.
    func plan(for spec: CustomAgentSpec) -> Plan {
        let record = installs.store.record(agentID: spec.id)
        return Plan(
            agentID: spec.id,
            agentName: spec.name,
            pinnedInstall: record.map { "\($0.package) v\($0.resolvedVersion)" }
        )
    }

    /// Remove the agent's pinned install and its roster entry together, and
    /// return the roster that remains.
    ///
    /// The install goes first, but only into a reversible staged state. The
    /// durable install record is removed before the roster save, then both are
    /// restored if that typed save fails. Only after both records commit are
    /// the staged bytes destroyed. This keeps every failure retryable without
    /// returning to the original orphaned-install bug.
    @discardableResult
    func delete(agentID: String, from specs: [CustomAgentSpec]) throws -> [CustomAgentSpec] {
        let name = specs.first { $0.id == agentID }?.name ?? agentID
        let remaining = specs.filter { $0.id != agentID }
        var savedRoster = remaining
        do {
            try installs.purge(
                agentID: agentID,
                committingRegistry: {
                    switch store.save(remaining, affectedAgentID: agentID) {
                    case let .success(saved):
                        savedRoster = saved
                    case let .failure(error):
                        throw Failure.registryNotRemoved(
                            agent: name,
                            reason: error.localizedDescription
                        )
                    }
                },
                rollingBackRegistry: {
                    if case let .failure(error) = store.save(specs, affectedAgentID: agentID) {
                        throw error
                    }
                }
            )
        } catch let failure as Failure {
            throw failure
        } catch let error as AdapterInstallManager.PurgeError {
            throw Failure.rollbackIncomplete(agent: name, reason: error.localizedDescription)
        } catch {
            throw Failure.installNotRemoved(agent: name, reason: error.localizedDescription)
        }
        return savedRoster
    }
}
