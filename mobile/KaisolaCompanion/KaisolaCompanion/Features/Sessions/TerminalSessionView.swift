import Foundation
import SwiftUI

struct TerminalSessionView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var coordinator: CompanionConnectionCoordinator
    @State private var changingControl = false
    @State private var pendingPaste: Data?
    @State private var confirmPaste = false
    @State private var streamWaitExpired = false

    let sessionId: String

    private var session: CompanionSession? { store.session(for: sessionId) }
    private var isControlled: Bool {
        guard let session else { return false }
        return coordinator.hasTerminalControl(session)
    }

    var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    streamStatus(session)
                    ZStack {
                        KaisolaTheme.terminalBackground
                        if !hasTerminalSnapshot(session) {
                            VStack(spacing: 9) {
                                if streamIssue(session) == nil && !streamWaitExpired {
                                    ProgressView().tint(KaisolaTheme.accent)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .foregroundStyle(KaisolaTheme.accent)
                                }
                                Text(streamMessage(session))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if store.connection == .live && (streamIssue(session) != nil || streamWaitExpired) {
                                    Button("Reload terminal") {
                                        requestStream(session, force: true)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .tint(KaisolaTheme.accent)
                                }
                            }
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                        }
                        CompanionTerminalSurface(
                            output: terminalOutput(session),
                            streamEpoch: session.terminalStreamEpoch,
                            controlEnabled: isControlled,
                            onInput: handleInput,
                            onResize: { cols, rows in
                                Task { await coordinator.resizeTerminal(session, cols: cols, rows: rows) }
                            }
                        )
                        .opacity(hasTerminalSnapshot(session) ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    controlBar(session)
                }
                .background(KaisolaTheme.terminalBackground)
                .task(id: session.id) {
                    requestStream(session)
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    if store.connection == .live,
                       let current = store.session(for: session.id),
                       !hasTerminalSnapshot(current) {
                        streamWaitExpired = true
                    }
                }
                .onChange(of: store.connection) { previous, current in
                    guard previous != .live, current == .live else { return }
                    coordinator.setTerminalStream(projectId: session.projectId, sessionId: session.id, subscribed: true)
                }
                .onChange(of: session.terminalStreamEpoch) { _, epoch in
                    if epoch != nil { streamWaitExpired = false }
                }
                .onDisappear {
                    coordinator.setTerminalStream(projectId: session.projectId, sessionId: session.id, subscribed: false)
                    Task { await coordinator.releaseTerminalControl(session) }
                }
                .navigationTitle(session.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await toggleControl(session) }
                        } label: {
                            Label(isControlled ? "Done" : "Control", systemImage: isControlled ? "lock.open.fill" : "hand.tap")
                                .font(.caption.weight(.semibold))
                        }
                        .disabled(changingControl || (!store.canControlTerminals && !store.isPreview))
                    }
                }
                .confirmationDialog("Send this paste to the terminal?", isPresented: $confirmPaste, titleVisibility: .visible) {
                    Button("Send paste") {
                        guard let pendingPaste else { return }
                        self.pendingPaste = nil
                        Task { _ = await coordinator.sendTerminalInput(pendingPaste, to: session) }
                    }
                    Button("Cancel", role: .cancel) { pendingPaste = nil }
                } message: {
                    Text("This paste contains multiple lines or a large block of text. It will be sent exactly once.")
                }
            } else {
                ContentUnavailableView("Terminal ended", systemImage: "terminal")
            }
        }
    }

    private func terminalOutput(_ session: CompanionSession) -> String {
        // Legacy renderer projections contain logical lines rather than raw PTY
        // bytes. A terminal line feed does not imply carriage return, so use
        // CRLF here to avoid every fallback line drifting farther right.
        session.terminalOutput ?? (session.terminalLines ?? []).joined(separator: "\r\n")
    }

    private func hasTerminalSnapshot(_ session: CompanionSession) -> Bool {
        session.terminalStreamEpoch != nil || !terminalOutput(session).isEmpty
    }

    private func streamIssue(_ session: CompanionSession) -> String? {
        coordinator.terminalStreamIssues[session.id]
    }

    private func streamMessage(_ session: CompanionSession) -> String {
        if store.connection != .live { return store.connection.title }
        if let issue = streamIssue(session) { return issue }
        return streamWaitExpired ? "The Mac has not sent this terminal yet." : "Loading terminal…"
    }

    private func requestStream(_ session: CompanionSession, force: Bool = false) {
        streamWaitExpired = false
        coordinator.setTerminalStream(
            projectId: session.projectId,
            sessionId: session.id,
            subscribed: true,
            force: force
        )
    }

    private func streamStatus(_ session: CompanionSession) -> some View {
        HStack(spacing: 8) {
            PulseDot(color: store.connection == .live ? KaisolaTheme.done : .secondary, size: 5)
            Text(isControlled ? "CONTROLLED" : "LIVE VIEW")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(isControlled ? KaisolaTheme.accent : .secondary)
            if let offset = session.terminalEndOffset {
                Text("· \(offset) bytes")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: isControlled ? "lock.open.fill" : "eye")
                .font(.caption2)
                .foregroundStyle(isControlled ? KaisolaTheme.accent : Color.secondary.opacity(0.55))
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func controlBar(_ session: CompanionSession) -> some View {
        if isControlled {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    key("esc", bytes: [0x1b], session: session)
                    key("tab", bytes: [0x09], session: session)
                    key("←", text: "\u{1b}[D", session: session)
                    key("↑", text: "\u{1b}[A", session: session)
                    key("↓", text: "\u{1b}[B", session: session)
                    key("→", text: "\u{1b}[C", session: session)
                    Button {
                        Task { _ = await coordinator.interruptTerminal(session) }
                    } label: {
                        Text("⌃C").terminalKeyStyle()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 48)
            .background(.ultraThinMaterial)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                Text(store.canControlTerminals || store.isPreview
                     ? "View only · tap Control to type"
                     : "View only · enable terminal control on your Mac")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(.ultraThinMaterial)
        }
    }

    private func key(_ title: String, text: String, session: CompanionSession) -> some View {
        key(title, bytes: Array(text.utf8), session: session)
    }

    private func key(_ title: String, bytes: [UInt8], session: CompanionSession) -> some View {
        Button {
            Task { _ = await coordinator.sendTerminalInput(Data(bytes), to: session) }
        } label: {
            Text(title.uppercased()).terminalKeyStyle()
        }
        .buttonStyle(.plain)
    }

    private func handleInput(_ data: Data) {
        guard let session else { return }
        let newlineCount = data.reduce(into: 0) { count, byte in
            if byte == 0x0a || byte == 0x0d { count += 1 }
        }
        if data.count > 4 * 1024 || newlineCount > 4 {
            pendingPaste = data
            confirmPaste = true
            return
        }
        Task { _ = await coordinator.sendTerminalInput(data, to: session) }
    }

    private func toggleControl(_ session: CompanionSession) async {
        changingControl = true
        defer { changingControl = false }
        if isControlled { await coordinator.releaseTerminalControl(session) }
        else { _ = await coordinator.acquireTerminalControl(session) }
    }
}

private extension Text {
    func terminalKeyStyle() -> some View {
        self
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.secondary)
            .frame(minWidth: 40, minHeight: 31)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
    }
}
