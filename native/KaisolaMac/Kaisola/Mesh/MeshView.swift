import SwiftUI

/// The Mesh surface: one composer fanning a prompt to every agent column;
/// side-by-side streaming transcripts; per-column status, inline permission
/// answers, and a worktree diff sheet for judging each agent's edits.
struct MeshView: View {
    enum Presentation: Sendable, Equatable {
        case standard
        case embedded
    }

    @ObservedObject var mesh: MeshSession
    private let presentation: Presentation
    @State private var diffColumnID: String?
    @State private var diffText = ""
    @State private var integrateColumnID: String?
    @State private var integrationStatus: String?

    init(mesh: MeshSession, presentation: Presentation = .standard) {
        _mesh = ObservedObject(wrappedValue: mesh)
        self.presentation = presentation
    }

    var body: some View {
        VStack(spacing: 0) {
            if presentation == .standard {
                header
                Divider()
            }
            if let status = integrationStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isConflictStatus(status) ? .orange : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                Divider()
            }
            if mesh.columns.isEmpty {
                if mesh.lifecycle == .recoveryRequired {
                    ContentUnavailableView {
                        Label("Mesh recovery needed", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("Kaisola preserved this run's Git manifest but could not safely reattach every worktree. Nothing was deleted.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("Starting agents…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(mesh.columns.enumerated()), id: \.element.id) { index, column in
                        if index > 0 { Divider() }
                        MeshColumnView(
                            column: column,
                            enablesPermissionShortcuts: column.id == firstPermissionColumnID,
                            stop: { Task { await mesh.stopTurn(columnID: column.id) } },
                            showDiff: { diffColumnID = column.id },
                            integrate: { integrateColumnID = column.id }
                        )
                    }
                }
            }
            Divider()
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .confirmationDialog(
            "Apply this column's diff to the base project?",
            isPresented: Binding(
                get: { integrateColumnID != nil },
                set: { if !$0 { integrateColumnID = nil } }
            ),
            presenting: integrateColumnID
        ) { columnID in
            Button("Apply Diff") { integrate(columnID) }
            Button("Cancel", role: .cancel) { integrateColumnID = nil }
        } message: { _ in
            Text("Grafts this column's edits onto \(mesh.baseDirectory.lastPathComponent) with a 3-way merge. Conflicts leave git markers you'll need to resolve.")
        }
        .sheet(item: Binding(
            get: { diffColumnID.map(DiffSheetID.init) },
            set: { diffColumnID = $0?.id }
        )) { sheet in
            VStack(spacing: 0) {
                HStack {
                    Text("Worktree diff — \(mesh.columns.first { $0.id == sheet.id }?.agent.name ?? "")")
                        .font(.headline)
                    Spacer()
                    Button("Done") { diffColumnID = nil }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
                Divider()
                ScrollView {
                    UnifiedPatchView(patch: diffText.isEmpty ? "No changes yet." : diffText)
                        .padding(12)
                }
            }
            .frame(width: 640, height: 480)
            .task { diffText = await mesh.diff(for: sheet.id) }
        }
    }

    private struct DiffSheetID: Identifiable {
        let id: String
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.purple)
            Text(mesh.title).font(.subheadline.weight(.medium))
            if let chip = headerChip {
                Text(chip)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.purple.opacity(0.15)))
            }
            if mesh.anyRunning {
                ProgressView().controlSize(.small)
            }
            if let note = mesh.isolationNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            MeshStagedPromptQueueButton(mesh: mesh)
            if mesh.anyRunning {
                Button {
                    Task { await mesh.stopAllTurns() }
                } label: {
                    Label("Stop All", systemImage: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("Stop every running Mesh column without deleting the run")
            }
            configurationMenu
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(.ultraThinMaterial)
    }

    private var configurationMenu: some View {
        MeshConfigurationMenu(mesh: mesh)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Send to every agent…", text: $mesh.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(mesh.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Fan this prompt out to every column")
        }
        .padding(10)
        .background(.ultraThinMaterial)
    }

    private func send() {
        let text = mesh.draft
        let accepted: Bool
        switch (mesh.purpose, mesh.mode) {
        case (.idea, _): accepted = mesh.sendIdea(text)
        case (.build, .staged): accepted = mesh.sendStaged(text)
        case (.build, .flat): accepted = mesh.send(text)
        }
        if accepted {
            mesh.draft = ""
        }
    }

    /// The header status chip: the run's purpose plus, when a staged/idea
    /// pipeline is active, its current phase. Nil for a plain flat build run.
    private var headerChip: String? {
        let queued = mesh.stagedQueuedPromptCount > 0
            ? " · \(mesh.stagedQueuedPromptCount) queued"
            : ""
        switch mesh.purpose {
        case .idea:
            return mesh.stage == "Idle" ? "Idea" : "Idea · \(mesh.stage)"
        case .build:
            return mesh.mode == .staged ? "Staged · \(mesh.stage)\(queued)" : nil
        }
    }

    private var firstPermissionColumnID: String? {
        mesh.columns.first { $0.conversation.pendingPermission != nil }?.id
    }

    /// Fetch the column's worktree diff and graft it onto the base workspace.
    /// Success and conflict/error alike surface in the status line under the
    /// header. Runs on the main actor so the @State write is safe.
    private func integrate(_ columnID: String) {
        let name = mesh.columns.first { $0.id == columnID }?.agent.name ?? "column"
        let base = mesh.baseDirectory
        Task { @MainActor in
            let patch = await mesh.diff(for: columnID)
            guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                integrationStatus = "\(name): no changes to apply."
                return
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try GitService(repoRoot: base).applyPatch(patch)
                }.value
                integrationStatus = "Applied \(name)'s diff to \(base.lastPathComponent)."
            } catch {
                integrationStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func isConflictStatus(_ status: String) -> Bool {
        status.range(of: "conflict", options: .caseInsensitive) != nil
            || status.range(of: "marker", options: .caseInsensitive) != nil
    }
}

/// Shared by standalone and embedded Mesh headers so a restored queue is never
/// hidden behind a particular presentation mode.
struct MeshStagedPromptQueueButton: View {
    @ObservedObject var mesh: MeshSession
    @State private var isPresented = false

    var body: some View {
        if !mesh.stagedPrompts.isEmpty {
            Button {
                isPresented.toggle()
            } label: {
                Label("\(mesh.stagedPrompts.count)", systemImage: "tray.full")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .help("Review queued Mesh prompts")
            .accessibilityLabel(queueAccessibilityLabel)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                queueInspector
            }
        }
    }

    private var queueAccessibilityLabel: String {
        let count = mesh.stagedPrompts.count
        return "Review \(count) queued \(count == 1 ? "prompt" : "prompts")"
    }

    private var queueInspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Queued Prompts")
                        .font(.headline)
                    Text("Waiting in dispatch order")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    _ = mesh.resumeStagedQueue()
                } label: {
                    Label("Resume Queue", systemImage: "play.fill")
                }
                .disabled(!mesh.canResumeStagedQueue)
                .help("Dispatch the oldest waiting prompt")
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(mesh.stagedPrompts.enumerated()), id: \.offset) { index, prompt in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("Prompt \(index + 1)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(role: .destructive) {
                                    if mesh.removeStagedPrompt(prompt, at: index), mesh.stagedPrompts.isEmpty {
                                        isPresented = false
                                    }
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove queued prompt \(index + 1)")
                            }
                            Text(prompt)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(
                            Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Queued prompt \(index + 1)")
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 390, height: 360)
    }
}

/// Compact configuration accessory shared by the standalone Mesh header and
/// the unified session-card header. Session identity and activity therefore
/// appear once while current ACP/MCP configuration remains one click away.
struct MeshConfigurationMenu: View {
    @ObservedObject var mesh: MeshSession

    var body: some View {
        Menu {
            Section("Project") {
                Label(mesh.baseDirectory.path, systemImage: "folder")
            }
            Section("ACP adapters") {
                if mesh.configuredAgentNames.isEmpty {
                    Text("No compatible adapters")
                } else {
                    ForEach(mesh.configuredAgentNames, id: \.self) { name in
                        Label(name, systemImage: "checkmark.circle")
                    }
                }
            }
            Section("MCP servers") {
                if mesh.configuredMCPServerNames.isEmpty {
                    Text("No enabled servers")
                } else {
                    ForEach(mesh.configuredMCPServerNames, id: \.self) { name in
                        Label(name, systemImage: "server.rack")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                Text("\(mesh.configuredAgentNames.count) ACP · \(mesh.configuredMCPServerNames.count) MCP")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .kaisolaControlSurface(active: true, tint: .purple)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Current project ACP and MCP configuration")
    }
}

/// One agent's column: status, streaming transcript, inline permission answers,
/// and the worktree diff affordance.
private struct MeshColumnView: View {
    let column: MeshSession.Column
    let enablesPermissionShortcuts: Bool
    let stop: () -> Void
    let showDiff: () -> Void
    let integrate: () -> Void
    @ObservedObject private var conversation: AcpConversation
    @State private var transcriptIsReady = false
    @State private var loadingEarlierRows = false
    @State private var transcriptIsAtBottom = true
    @State private var hasUnseenTranscriptUpdates = false

    init(
        column: MeshSession.Column,
        enablesPermissionShortcuts: Bool,
        stop: @escaping () -> Void,
        showDiff: @escaping () -> Void,
        integrate: @escaping () -> Void
    ) {
        self.column = column
        self.enablesPermissionShortcuts = enablesPermissionShortcuts
        self.stop = stop
        self.showDiff = showDiff
        self.integrate = integrate
        self.conversation = column.conversation
    }

    /// A dotted ring, a filled disc, and a hollow ring — three shapes, so the
    /// tint below is reinforcement rather than the only way to read the state.
    private var statusSymbol: String {
        if conversation.isRunning { return "circle.dotted" }
        return conversation.isConnected ? "circle.fill" : "circle"
    }

    private var statusTint: Color {
        if conversation.isRunning { return .accentColor }
        return conversation.isConnected ? .green : .secondary
    }

    private var statusDescription: String {
        if conversation.isRunning { return "Working" }
        return conversation.isConnected ? "Connected" : "Not connected"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: column.agent.symbol).foregroundStyle(.purple)
                Text(column.agent.name).font(.callout.weight(.semibold))
                // Three states off one tinted dot meant colour was the whole
                // signal. Each state now has its own outline as well, and says
                // its name to VoiceOver and on hover.
                Image(systemName: statusSymbol)
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(statusTint)
                    .accessibilityElement()
                    .accessibilityLabel("\(column.agent.name): \(statusDescription)")
                    .help(statusDescription)
                Spacer()
                if conversation.isRunning {
                    Button(action: stop) {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop \(column.agent.name) without deleting its transcript")
                    .accessibilityLabel("Stop \(column.agent.name) turn")
                }
                if column.worktreePath != nil {
                    Button("Diff", action: showDiff)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("This column's isolated worktree diff vs HEAD")
                    Button("Integrate", action: integrate)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Apply this column's diff onto the base project")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.thinMaterial)
            Divider()
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if conversation.hiddenEarlierCount > 0 {
                                HStack(spacing: 6) {
                                    if loadingEarlierRows { ProgressView().controlSize(.mini) }
                                    Text(loadingEarlierRows ? "Loading earlier messages…" : "Earlier messages")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .onAppear {
                                    guard transcriptIsReady,
                                          !loadingEarlierRows,
                                          let anchor = conversation.visibleRows.first?.id else { return }
                                    loadingEarlierRows = true
                                    conversation.expandEarlier()
                                    DispatchQueue.main.async {
                                        TerminalTranscriptScrollPolicy.preserveUserVelocity {
                                            proxy.scrollTo(anchor, anchor: .top)
                                        }
                                        loadingEarlierRows = false
                                    }
                                }
                            } else if transcriptIsReady, !conversation.rows.isEmpty {
                                Text("Beginning of session")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                            }
                            if let status = conversation.statusMessage {
                                Label(status, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(conversation.visibleRows) { row in
                                TranscriptRowView(
                                    row: row,
                                    retry: { conversation.retryFailed($0) },
                                    terminalSnapshot: { [weak conversation] id in await conversation?.terminalSnapshot(id) }
                                )
                                .id(row.id)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("mesh-transcript-bottom-\(column.id)")
                                .onAppear {
                                    transcriptIsAtBottom = true
                                    hasUnseenTranscriptUpdates = false
                                }
                                .onDisappear { transcriptIsAtBottom = false }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if transcriptIsReady, !transcriptIsAtBottom, !conversation.rows.isEmpty {
                        Button {
                            hasUnseenTranscriptUpdates = false
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("mesh-transcript-bottom-\(column.id)", anchor: .bottom)
                            }
                        } label: {
                            Image(systemName: hasUnseenTranscriptUpdates ? "arrow.down.circle.fill" : "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(8)
                        .help(hasUnseenTranscriptUpdates ? "Jump to new output" : "Jump to latest")
                        .accessibilityLabel(hasUnseenTranscriptUpdates ? "Jump to new agent output" : "Jump to latest agent output")
                    }
                }
                .onAppear {
                    transcriptIsReady = false
                    transcriptIsAtBottom = true
                    hasUnseenTranscriptUpdates = false
                    DispatchQueue.main.async {
                        proxy.scrollTo("mesh-transcript-bottom-\(column.id)", anchor: .bottom)
                        transcriptIsReady = true
                    }
                }
                .onChange(of: conversation.contentVersion) { _, _ in
                    guard transcriptIsReady else { return }
                    if transcriptIsAtBottom {
                        DispatchQueue.main.async {
                            proxy.scrollTo("mesh-transcript-bottom-\(column.id)", anchor: .bottom)
                        }
                    } else {
                        hasUnseenTranscriptUpdates = true
                    }
                }
            }
            if let permission = conversation.pendingPermission {
                Divider()
                AcpPermissionBar(
                    request: permission,
                    allowsRule: conversation.pendingPermissionAllowsRule,
                    pendingCount: conversation.pendingPermissionCount,
                    answer: { conversation.answerPermission($0) },
                    always: { conversation.answerPermissionAlways() },
                    enablesKeyboardShortcuts: enablesPermissionShortcuts
                )
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .task { await conversation.start() }
    }
}

/// A raw unified diff with the standard +/− tinting (shared Mesh/diff-sheet
/// rendering).
struct UnifiedPatchView: View {
    let patch: String

    private var rendered: GitBoundedPatch { GitPatchRendering.bounded(patch) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rendered.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 3)
                    .background(tint(for: line))
            }
            if rendered.isTruncated {
                Label("Large diff truncated in this view", systemImage: "ellipsis.rectangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
    }

    private func tint(for line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .green.opacity(0.13) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .red.opacity(0.13) }
        if line.hasPrefix("@@") { return .accentColor.opacity(0.13) }
        return .clear
    }
}
