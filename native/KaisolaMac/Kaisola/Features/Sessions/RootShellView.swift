import AppKit
import SwiftUI

struct RootShellView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { model.selectedSessionID },
                set: { id in Task { await model.select(id) } }
            )) {
                ForEach(model.projects, id: \.name) { project in
                    Section(project.name) {
                        ForEach(project.sessions) { session in
                            SessionRow(session: session, owned: model.isOwned(session.id))
                                .tag(Optional(session.id))
                                .contextMenu {
                                    if model.isOwned(session.id) && !session.exited {
                                        Button("End Session", role: .destructive) {
                                            Task { await model.endSession(session.id) }
                                        }
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 235, max: 300)
            .safeAreaInset(edge: .bottom) {
                ConnectionFooter(
                    state: model.connectionState,
                    canCreate: model.controlAvailable,
                    reload: { Task { await model.reload() } },
                    newTerminal: { RootShellView.promptForNewTerminal(model: model) }
                )
            }
            .accessibilityLabel("Projects and terminal sessions")
        } detail: {
            VStack(spacing: 0) {
                StatusBar(
                    state: model.connectionState,
                    ownsSelection: model.selectedSessionID.map(model.isOwned) ?? false
                )
                Divider()
                terminalContent
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Folder picker → new owned shell in that directory. Reused by the File
    /// menu and the sidebar button.
    @MainActor
    static func promptForNewTerminal(model: AppModel) {
        guard model.controlAvailable else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Terminal Here"
        panel.message = "Choose the folder for the new terminal session."
        guard panel.runModal() == .OK, let directory = panel.urls.first else { return }
        Task { await model.createTerminal(inDirectory: directory) }
    }

    @ViewBuilder
    private var terminalContent: some View {
        if let message = model.terminalDocument.errorMessage {
            ContentUnavailableView(
                "Terminal unavailable",
                systemImage: "terminal",
                description: Text(message)
            )
        } else if model.terminalDocument.sessionID == nil {
            ContentUnavailableView(
                model.sessions.isEmpty ? "No observable sessions" : "Choose a terminal",
                systemImage: "terminal",
                description: Text("Electron remains the controller. This preview only observes durable output.")
            )
        } else {
            let sessionID = model.terminalDocument.sessionID
            let owned = sessionID.map(model.isOwned) ?? false
            ZStack(alignment: .topTrailing) {
                NativeTerminalSurface(
                    output: model.terminalDocument.output,
                    streamEpoch: model.terminalDocument.cursor?.streamEpoch,
                    endOffset: model.terminalDocument.cursor?.offset,
                    isOwned: owned,
                    onInput: owned ? { data in
                        guard let sessionID else { return }
                        model.sendInput(data, to: sessionID)
                    } : nil,
                    onResize: owned ? { columns, rows in
                        guard let sessionID else { return }
                        model.resizeTerminal(sessionID, columns: columns, rows: rows)
                    } : nil
                )
                .id("\(sessionID ?? "none")-\(owned)")
                if model.terminalDocument.truncated {
                    Label("Retained tail", systemImage: "ellipsis.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                        .accessibilityLabel("Older terminal output was outside the retained history")
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: BrokerTerminalRecord
    let owned: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: owned ? "terminal.fill" : "terminal")
                .foregroundStyle(session.exited ? Color.secondary : owned ? Color.accentColor : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text(sessionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var sessionDetail: String {
        if session.exited { return "Finished" }
        let liveDetail = "Live · PID \(session.pid.map(String.init) ?? "—")"
        return owned ? liveDetail : "\(liveDetail) · observed"
    }
}

private struct StatusBar: View {
    let state: AppModel.ConnectionState
    let ownsSelection: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state.isConnected ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 7, height: 7)
            Text(state.title)
                .font(.subheadline.weight(.medium))
            if let detail = state.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if ownsSelection {
                Label("Interactive", systemImage: "keyboard")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("This terminal accepts keyboard input")
            } else {
                Label("Read only", systemImage: "eye")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("Terminal access is read only")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }
}

private struct ConnectionFooter: View {
    let state: AppModel.ConnectionState
    let canCreate: Bool
    let reload: () -> Void
    let newTerminal: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Native preview")
                    .font(.caption.weight(.semibold))
                Text(state.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if canCreate {
                Button(action: newTerminal) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New terminal session (⌘T)")
                .accessibilityLabel("New terminal session")
            }
            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reconnect without changing terminal ownership")
            .accessibilityLabel("Reconnect to terminal broker")
        }
        .padding(12)
        .background(.bar)
    }
}
