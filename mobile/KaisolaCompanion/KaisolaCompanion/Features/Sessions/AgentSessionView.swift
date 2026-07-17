import SwiftUI

struct AgentSessionView: View {
    @EnvironmentObject private var store: CompanionStore
    let sessionId: String
    @State private var draft = ""

    private var session: CompanionSession? { store.session(for: sessionId) }

    var body: some View {
        ZStack {
            AmbientBackdrop()

            if let session {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        sessionHeader(session)
                        ControlLockedBanner(text: "Messages remain on this iPhone until secure pairing ships.")
                        ForEach(session.turns ?? []) { turn in
                            TranscriptTurnView(turn: turn)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 76)
                }
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom) { composer }
            }
        }
        .navigationTitle(session?.provider ?? "Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let session { StatusBadge(status: session.status) }
            }
        }
    }

    private func sessionHeader(_ session: CompanionSession) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("AGENT SESSION")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.3)
                    .foregroundStyle(KaisolaTheme.accent)
                Spacer()
                Image(systemName: "sparkle")
                    .foregroundStyle(KaisolaTheme.accent)
            }
            Text(session.title)
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .tracking(-0.6)
            HStack(spacing: 6) {
                if let model = session.model { Text(model) }
                if let mode = session.mode { Text("/"); Text(mode) }
                if let branch = session.branch { Text("/"); Text(branch) }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.bottom, 4)
    }

    private var composer: some View {
        VStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 9) {
                TextField("Message agent", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
                    }
                Button {
                    store.sendPreviewPrompt(to: sessionId, text: draft)
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(
                            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : KaisolaTheme.accent,
                            in: Circle()
                        )
                }
                .buttonStyle(QuietPressStyle())
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send preview prompt")
            }
            Text("LOCAL PREVIEW / LIVE CONTROL LOCKED")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(0.75)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }
}

private struct TranscriptTurnView: View {
    let turn: CompanionTurn

    var body: some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 44)
                Text(turn.text)
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        LinearGradient(
                            colors: [KaisolaTheme.accent.opacity(0.94), KaisolaTheme.accent.opacity(0.76)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                    )
                    .foregroundStyle(.white)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(KaisolaTheme.accent)
                    .frame(width: 2, height: 34)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Text("AGENT")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(KaisolaTheme.accent)
                        if turn.status == "streaming" {
                            PulseDot(color: KaisolaTheme.running, size: 4)
                        }
                    }
                    Text(turn.text)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
        case .thought, .tool:
            DisclosureGroup {
                Text(turn.text)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.top, 9)
            } label: {
                Label(
                    turn.role == .thought ? "Reasoning" : "Tool result",
                    systemImage: turn.role == .thought ? "brain.head.profile" : "wrench.and.screwdriver"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .kaisolaCard(padding: 13)
        }
    }
}
